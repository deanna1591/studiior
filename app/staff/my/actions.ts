"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

export type MyState = { ok: boolean; message: string } | null;

const say = (m: string) =>
  /PT403/.test(m) ? "That is not yours to change."
  : /PT404/.test(m) ? "That is no longer there."
  : /PT409/.test(m) ? m.replace(/^.*?:\s*/, "")
  : /PT422/.test(m) ? m.replace(/^.*?:\s*/, "")
  : m;

/**
 * The month ahead, submitted for approval.
 *
 * Same payload shape as `set_instructor_availability()` — the editor is the
 * same editor. A manager calling this lands approved, which is the database's
 * rule and not this screen's: staff entry IS approval, and every row that
 * existed before migration 066 was entered by staff.
 */
export async function submitAvailability(_prev: MyState, fd: FormData): Promise<MyState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const instructorId = String(fd.get("instructor_id") ?? "");
  const period = String(fd.get("period_start") ?? "");
  const submit = String(fd.get("submit") ?? "1") === "1";
  if (!instructorId || !period) return { ok: false, message: "Nothing to submit." };

  let days: unknown;
  try { days = JSON.parse(String(fd.get("days") ?? "[]")); }
  catch { return { ok: false, message: "That month did not come through. Try again." }; }

  const supabase = createClient();
  const { data, error } = await supabase.rpc("submit_availability", {
    p_instructor_id: instructorId,
    p_period_start: period,
    p_days: days as never,
    p_submit: submit,
  });
  if (error) return { ok: false, message: say(error.message) };

  const r = data as unknown as { status: string; ranges: number; auto_approved: boolean };
  revalidatePath("/my/availability");
  revalidatePath("/availability");
  return {
    ok: true,
    message: !submit
      ? `Saved as a draft. ${r.ranges} time ranges — nothing goes to the studio until you submit it.`
      : r.auto_approved
      ? `Saved and approved — you entered it yourself, so there is nothing to review.`
      : `Submitted. The studio will approve it or come back to you; it does not affect scheduling until they do.`,
  };
}

/** One press for the whole week. */
export async function confirmWeek(_prev: MyState, fd: FormData): Promise<MyState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const supabase = createClient();
  const { data, error } = await supabase.rpc("confirm_week", {
    p_instructor_id: String(fd.get("instructor_id") ?? ""),
    p_week_start: String(fd.get("week_start") ?? ""),
  });
  if (error) return { ok: false, message: say(error.message) };
  const r = data as unknown as { confirmed: number; cover_requested: number };
  revalidatePath("/my/week");
  revalidatePath("/");
  return {
    ok: true,
    message: r.confirmed === 0
      ? "Nothing left to confirm."
      : `${r.confirmed} ${r.confirmed === 1 ? "class" : "classes"} confirmed.` +
        (r.cover_requested > 0
          ? ` The ${r.cover_requested} you asked for cover on are with the studio.`
          : ""),
  };
}

/**
 * Cover on one class, through Decision 18's flow.
 *
 * Requesting cover does NOT cancel the class and does not release the
 * instructor — staff always approve. The screen says so rather than letting the
 * button imply otherwise.
 */
export async function askForCover(_prev: MyState, fd: FormData): Promise<MyState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const supabase = createClient();
  const { error } = await supabase.rpc("request_cover", {
    p_occurrence_id: String(fd.get("occurrence_id") ?? ""),
    p_reason: String(fd.get("reason") ?? "").trim() || undefined,
  });
  if (error) return { ok: false, message: say(error.message) };
  revalidatePath("/my/week");
  revalidatePath("/shifts/cover");
  return {
    ok: true,
    message: "Asked. You are still down to teach it until the studio answers.",
  };
}

/** Manager-up. Both guarded in the database; the screen is not the boundary. */
export async function approveSubmission(_prev: MyState, fd: FormData): Promise<MyState> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("approve_availability_submission", {
    p_submission_id: String(fd.get("submission_id") ?? ""),
  });
  if (error) return { ok: false, message: say(error.message) };
  const r = data as unknown as { instructor: string; notified: boolean };
  revalidatePath("/availability");
  revalidatePath("/schedule");
  return {
    ok: true,
    message: r.notified
      ? `Approved. ${r.instructor} has been emailed.`
      : `Approved. ${r.instructor} has no login, so nothing was emailed — tell them yourself.`,
  };
}

export async function requestChanges(_prev: MyState, fd: FormData): Promise<MyState> {
  const note = String(fd.get("note") ?? "").trim();
  if (!note) return { ok: false, message: "Say what needs changing." };
  const supabase = createClient();
  const { data, error } = await supabase.rpc("request_availability_changes", {
    p_submission_id: String(fd.get("submission_id") ?? ""),
    p_note: note,
  });
  if (error) return { ok: false, message: say(error.message) };
  const r = data as unknown as { instructor: string; notified: boolean };
  revalidatePath("/availability");
  return {
    ok: true,
    message: r.notified
      ? `Sent back to ${r.instructor} with your note.`
      : `Recorded. ${r.instructor} has no login, so nothing was emailed — tell them yourself.`,
  };
}
