"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type InstructorState = { error: string } | { ok: string } | null;

/**
 * Everything an instructor can DO, in one place.
 *
 * Every one of these is a function that already existed and already decided
 * who may call it — confirm_week, request_cover, apply_for_shift,
 * withdraw_from_shift, submit_availability. Nothing here is a second opinion
 * about a permission; the database refuses and this renders the sentence.
 *
 * WHAT IS DELIBERATELY ABSENT: there is no "release this class". Decision 18
 * overturned that edge of Decision 17 — staff always grant cover, however
 * urgent, and withdraw_from_shift() raises a cover request instead of clearing
 * the instructor. A button that looked like self-release would be a button
 * that lies.
 */
export async function confirmMyWeek(
  _prev: InstructorState, form: FormData,
): Promise<InstructorState> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("confirm_week", {
    p_instructor_id: String(form.get("instructor_id")),
    p_week_start: String(form.get("week_start")),
  });
  if (error) return { error: error.message };
  const r = (data ?? {}) as { confirmed?: number; skipped_cover?: number };
  revalidatePath("/instructor");
  return {
    ok: `${r.confirmed ?? 0} confirmed.` +
      (r.skipped_cover
        ? ` ${r.skipped_cover} left alone — you have asked for cover on ${r.skipped_cover === 1 ? "it" : "those"}.`
        : ""),
  };
}

/**
 * Decision 25. One press for the whole month. Classes they have asked cover
 * for are the flag, not an obstacle; the database says how many.
 */
export async function confirmMyMonth(
  _prev: InstructorState, form: FormData,
): Promise<InstructorState> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("confirm_month_roster", {
    p_instructor_id: String(form.get("instructor_id")),
    p_month: String(form.get("month")),
  });
  if (error) return { error: error.message };
  const r = (data ?? {}) as { classes?: number; cover_requested?: number };
  revalidatePath("/instructor");
  revalidatePath("/instructor/month");
  return {
    ok: `Confirmed — ${r.classes ?? 0} ${r.classes === 1 ? "class" : "classes"}.` +
      (r.cover_requested
        ? ` ${r.cover_requested} of ${r.cover_requested === 1 ? "them is" : "them are"} waiting on cover; the studio decides those.`
        : ""),
  };
}

export async function askForCover(
  _prev: InstructorState, form: FormData,
): Promise<InstructorState> {
  const reason = String(form.get("reason") ?? "").trim();
  if (!reason) return { error: "Say why, so the studio can decide." };
  const supabase = createClient();
  const { error } = await supabase.rpc("request_cover", {
    p_occurrence_id: String(form.get("occurrence_id")),
    p_reason: reason,
  });
  if (error) return { error: error.message };
  revalidatePath("/instructor");
  revalidatePath("/instructor/month");
  return { ok: "Asked. The studio decides — you are still down to teach it until they do." };
}

export async function applyForShift(
  _prev: InstructorState, form: FormData,
): Promise<InstructorState> {
  const supabase = createClient();
  const { error } = await supabase.rpc("apply_for_shift", {
    p_occurrence_id: String(form.get("occurrence_id")),
    p_note: String(form.get("note") ?? "") || undefined,
  });
  if (error) return { error: error.message };
  revalidatePath("/instructor/shifts");
  return { ok: "Applied. Staff approve it — you will hear back." };
}

export type ClaimState =
  | { error: string }
  | { ok: string }
  | { overCap: { current: number; cap: number } }
  | null;

/**
 * Claiming (migration 149): the instructor claims an open class; staff approve.
 * apply_for_shift is the primitive — at a claiming studio it returns
 * {ok:false, reason} rather than raising for the soft/hard gates, so this reads
 * the payload rather than only `error`. Over the core cap it does not refuse
 * outright: it comes back over_cap with the numbers, and the caller offers "ask
 * anyway" (p_over_cap_ack), which records the flag for staff.
 */
export async function claimClass(_prev: ClaimState, form: FormData): Promise<ClaimState> {
  const supabase = createClient();
  const ack = String(form.get("over_cap_ack") ?? "") === "1";
  const { data, error } = await supabase.rpc("apply_for_shift", {
    p_occurrence_id: String(form.get("occurrence_id")),
    p_note: String(form.get("note") ?? "") || undefined,
    p_over_cap_ack: ack,
  });
  if (error) return { error: error.message };
  const r = (data ?? {}) as {
    ok?: boolean; reason?: string; current?: number; cap?: number; over_cap?: boolean;
  };
  if (r.ok) {
    revalidatePath("/instructor/shifts");
    return {
      ok: r.over_cap
        ? "Claimed — over your usual cap for the week, so the studio will see that. They decide."
        : "Claimed. The studio approves it — you will hear back.",
    };
  }
  if (r.reason === "over_cap") return { overCap: { current: r.current ?? 0, cap: r.cap ?? 0 } };
  if (r.reason === "outside_validity")
    return { error: "That is outside the availability you have given us for that month. Send it in and the class opens up." };
  return { error: "That could not be claimed." };
}

/**
 * Auto-accept cover (156): an instructor takes an urgent, auto-acceptable cover.
 * The database checks qualified / valid / available / not-clashing and assigns
 * through move_occurrence — no staff approval, no cap (an urgent cover is not
 * hoarding a month). accept_cover returns {ok:false} with move's reason on a
 * clash, which can happen if two instructors race for it.
 */
export async function acceptCover(_prev: InstructorState, form: FormData): Promise<InstructorState> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("accept_cover", {
    p_occurrence_id: String(form.get("occurrence_id")),
  });
  if (error) {
    const m = error.message;
    return { error: /PT409/.test(m) ? "Somebody else has taken it, or it needs the studio to approve." : m };
  }
  const r = (data ?? {}) as { ok?: boolean; reason?: string };
  if (!r.ok) return { error: r.reason === "instructor_busy" ? "You are already teaching then." : "Somebody else has just taken it." };
  revalidatePath("/instructor");
  revalidatePath("/instructor/shifts");
  return { ok: "Taken — it is yours. The studio has been told." };
}

export async function withdrawApplication(
  _prev: InstructorState, form: FormData,
): Promise<InstructorState> {
  const supabase = createClient();
  // withdraw_application(), not withdraw_from_shift(): this is a PENDING
  // application on an open shift, where there is no assigned instructor —
  // withdraw_from_shift() requires being the one teaching it and refused here.
  const { error } = await supabase.rpc("withdraw_application", {
    p_occurrence_id: String(form.get("occurrence_id")),
  });
  if (error) return { error: error.message };
  revalidatePath("/instructor/shifts");
  return { ok: "Withdrawn." };
}

/**
 * §8 gives an instructor check-in. It does NOT give them "correct a no-show"
 * or "create a walk-in booking", so neither exists here or on the screen.
 */
export async function checkInMember(
  _prev: InstructorState, form: FormData,
): Promise<InstructorState> {
  const supabase = createClient();
  const occurrenceId = String(form.get("occurrence_id"));
  const { error } = await supabase.from("check_ins").insert({
    studio_id: String(form.get("studio_id")),
    booking_id: String(form.get("booking_id")),
    member_id: String(form.get("member_id")),
    occurrence_id: occurrenceId,
    method: "staff",
  });
  if (error) return { error: error.message };
  revalidatePath(`/instructor/roster/${occurrenceId}`);
  return { ok: "In." };
}


/**
 * Decision 28: the instructor checks themselves in for a class, so their pay is
 * released. One tap; the window and "your class" checks are in the function.
 */
export async function confirmClass(_prev: InstructorState, form: FormData): Promise<InstructorState> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("instructor_confirm_class", {
    p_occurrence_id: String(form.get("occurrence_id")),
  });
  if (error) return { error: error.message };
  const r = (data ?? {}) as { ok?: boolean };
  if (!r.ok) return { error: "That could not be confirmed." };
  revalidatePath("/instructor");
  return { ok: "Checked in — your pay for this class is released." };
}
