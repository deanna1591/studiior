"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

export type OpenShiftState =
  | { ok: true; message: string }
  | { ok: false; message: string }
  | null;

/**
 * Take an instructor off a class and publish it as an open shift.
 *
 * open_shift() clears the instructor, keeps the class bookable, tells the
 * instructor removed (or reports they have no login), and audits it. The
 * class stays exactly where it is on the calendar; only its staffing changes.
 */
export async function openShift(_prev: OpenShiftState, fd: FormData): Promise<OpenShiftState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const occurrenceId = String(fd.get("occurrence_id") ?? "");
  const reason = String(fd.get("reason") ?? "").trim();
  if (!reason) return { ok: false, message: "Say why — the instructor gets this, and it goes on the record." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("open_shift", {
    p_occurrence_id: occurrenceId, p_reason: reason,
  });
  if (error) return { ok: false, message: error.message };

  const r = data as unknown as {
    ok: boolean; reason?: string; removed_instructor: string;
    removed_notified: boolean; removed_uncontactable: boolean;
  };
  if (!r.ok) return { ok: false, message: r.reason ?? "That could not be done." };

  revalidatePath(`/roster/${occurrenceId}`);
  revalidatePath("/schedule");
  const tail = r.removed_uncontactable
    ? ` ${r.removed_instructor} has no login, so tell them yourself.`
    : ` ${r.removed_instructor} has been told.`;
  return { ok: true, message: `Opened as a shift.${tail} Qualified instructors are emailed shortly.` };
}

export type AssignState =
  | { ok: true; message: string }
  | { ok: false; message: string }
  | null;

/**
 * Assign an instructor to an unstaffed class, from the class itself.
 *
 * Through move_occurrence() — the same gate a drag uses — so it gets the same
 * validation: the validity-window hard refusal (they have not agreed to work
 * that date), the room/instructor clash, the availability warning. No time
 * changes, so nobody booked is emailed; move_occurrence only mails on a time
 * move, and the confirm flag is passed because assigning to a class with
 * members booked would otherwise ask a question that has no email behind it.
 */
export async function assignInstructor(_prev: AssignState, fd: FormData): Promise<AssignState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const occurrenceId = String(fd.get("occurrence_id") ?? "");
  const instructorId = String(fd.get("instructor_id") ?? "");
  if (!instructorId) return { ok: false, message: "Pick who is teaching it." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("move_occurrence", {
    p_occurrence_id: occurrenceId,
    p_instructor_id: instructorId,
    // Assigning to a previously-open class emails nobody (no time change), so
    // the members-booked confirmation has nothing to confirm — pass it.
    p_confirm: true,
  });
  if (error) {
    const m = error.message;
    return {
      ok: false,
      message: /PT403/.test(m) ? "Only owners and managers assign classes."
        : /PT402/.test(m) ? "This studio's Studiior subscription is not active."
        : m,
    };
  }

  const r = data as unknown as {
    ok: boolean; reason?: string;
    blocked_by?: { who?: string | null; on?: string | null; name?: string | null; at?: string | null } | null;
  };
  if (!r.ok) {
    const b = r.blocked_by;
    const msg =
      r.reason === "outside_availability_dates"
        ? `${b?.who ?? "They"} have not agreed to work on ${b?.on ?? "that date"} — that is dates they never agreed to, not hours, so it cannot be assigned here.`
      : r.reason === "instructor_busy"
        ? `They are already teaching ${b?.name ?? "another class"}${b?.at ? ` at ${b.at}` : ""}.`
      : r.reason === "room_busy"
        ? "The room is in use then."
      : "That could not be assigned.";
    return { ok: false, message: msg };
  }

  revalidatePath(`/roster/${occurrenceId}`);
  revalidatePath("/schedule");
  revalidatePath("/");
  return { ok: true, message: "Assigned. They are teaching this class now." };
}

/**
 * Swap a class's instructor for another, from the calendar's popover.
 *
 * reassign_occurrence() goes through move_occurrence() — the same gate as a drag
 * (validity window hard, room/double-booking, availability warning) — and tells
 * BOTH instructors: the one swapped in (move_occurrence's assigned notice) and
 * the one swapped out (its own removal notice), both publication-gated.
 */
export async function reassignInstructor(_prev: AssignState, fd: FormData): Promise<AssignState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const occurrenceId = String(fd.get("occurrence_id") ?? "");
  const instructorId = String(fd.get("instructor_id") ?? "");
  if (!instructorId) return { ok: false, message: "Pick who is teaching it." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("reassign_occurrence", {
    p_occurrence_id: occurrenceId, p_instructor_id: instructorId,
  });
  if (error) {
    const m = error.message;
    return {
      ok: false,
      message: /PT403/.test(m) ? "Only owners and managers change the timetable."
        : /PT402/.test(m) ? "This studio's Studiior subscription is not active."
        : m,
    };
  }

  const r = data as unknown as {
    ok: boolean; reason?: string; new_instructor?: string;
    removed_instructor?: string | null; removed_uncontactable?: boolean;
    blocked_by?: { who?: string | null; on?: string | null; name?: string | null; at?: string | null } | null;
  };
  if (!r.ok) {
    const b = r.blocked_by;
    const msg =
      r.reason === "outside_availability_dates"
        ? `${b?.who ?? "They"} have not agreed to work on ${b?.on ?? "that date"} — that is dates they never agreed to, not hours, so it cannot be assigned here.`
      : r.reason === "instructor_busy"
        ? `They are already teaching ${b?.name ?? "another class"}${b?.at ? ` at ${b.at}` : ""}.`
      : r.reason === "room_busy"
        ? "The room is in use then."
      : "That could not be reassigned.";
    return { ok: false, message: msg };
  }

  revalidatePath(`/roster/${occurrenceId}`);
  revalidatePath("/schedule");
  revalidatePath("/");
  const tail = r.removed_uncontactable
    ? ` ${r.removed_instructor} has no login, so tell them yourself.`
    : r.removed_instructor ? ` ${r.removed_instructor} has been told.` : "";
  return { ok: true, message: `${r.new_instructor} is teaching it now.${tail}` };
}

export type RepublishState = { ok: boolean; message: string } | null;

/**
 * "Put it out to instructors again." An unstaffed class is already an open
 * shift and qualified instructors were emailed once; this clears the alert
 * latch so the next sweep re-solicits them — the honest action for a gap
 * nobody has applied for yet.
 */
export async function republishShift(_prev: RepublishState, fd: FormData): Promise<RepublishState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const occurrenceId = String(fd.get("occurrence_id") ?? "");

  const supabase = createClient();
  const { data, error } = await supabase.rpc("republish_open_shift", { p_occurrence_id: occurrenceId });
  if (error) {
    const m = error.message;
    return {
      ok: false,
      message: /PT403/.test(m) ? "Only owners and managers open a shift to instructors."
        : /PT409/.test(m) ? m.replace(/^.*?:\s*/, "")
        : m,
    };
  }
  const r = data as unknown as { ok?: boolean; qualified_contactable?: number } | null;
  if (!r?.ok) return { ok: false, message: "That could not be done." };

  revalidatePath(`/roster/${occurrenceId}`);
  const n = r.qualified_contactable ?? 0;
  return {
    ok: true,
    message: n > 0
      ? `Out to instructors. ${n} qualified instructor${n === 1 ? "" : "s"} with a login will be emailed shortly.`
      : "Out to instructors — but none of your qualified instructors have a login, so tell them yourself.",
  };
}

export type PaperWaiverState =
  | { ok: true; message: string }
  | { ok: false; message: string }
  | null;

/**
 * Decision 26 — front desk records a guest's waiver signed ON PAPER at the door.
 * Through record_document, so it is a real filed document (auditable), and that
 * confirms the guest's pass and clears the check-in gate — the studio hands an
 * unsigned guest a form rather than sending them home.
 */
export async function recordPaperWaiver(_prev: PaperWaiverState, fd: FormData): Promise<PaperWaiverState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const memberId = String(fd.get("member_id") ?? "");
  const occurrenceId = String(fd.get("occurrence_id") ?? "");

  const supabase = createClient();
  const { data, error } = await supabase.rpc("record_document", {
    p_member_id: memberId,
    p_kind: "waiver",
    p_filename: "Paper waiver (signed at the desk)",
    p_storage_path: `guest-paper-waiver/${memberId}/${Date.now()}`,
    p_note: "Signed on paper at the front desk.",
    p_signed_at: new Date().toISOString(),
  });
  if (error) return { ok: false, message: error.message };
  const r = data as unknown as { ok?: boolean } | null;
  if (!r?.ok) return { ok: false, message: "That could not be recorded." };

  revalidatePath(`/roster/${occurrenceId}`);
  return { ok: true, message: "Waiver recorded — you can check them in now." };
}

export type ReleasePayState = { ok: boolean; message: string } | null;

/**
 * Decision 28: a manager releases a held pay record on the instructor's behalf,
 * with a reason (audited). For when the instructor taught and forgot to tap.
 */
export async function releasePay(_prev: ReleasePayState, fd: FormData): Promise<ReleasePayState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "Not signed in." };
  const occurrenceId = String(fd.get("occurrence_id") ?? "");
  const reason = String(fd.get("reason") ?? "").trim();
  if (!reason) return { ok: false, message: "Say why — the instructor did the work, and this goes on the record." };
  const supabase = createClient();
  const { data, error } = await supabase.rpc("confirm_class_for_pay", { p_occurrence_id: occurrenceId, p_reason: reason });
  if (error) return { ok: false, message: error.message };
  const r = data as unknown as { ok?: boolean } | null;
  if (!r?.ok) return { ok: false, message: "That could not be released." };
  revalidatePath(`/roster/${occurrenceId}`);
  return { ok: true, message: "Released. The instructor's pay for this class is confirmed." };
}
