"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

/**
 * Decision 35 (a) — staff (and the class's coach) mark a member attended. One
 * path in the database, staff_mark_attended: booked after the class started
 * and before the day is finalised (desk-up or the coach), or a no-show (desk-up
 * or the coach until finalised; manager-up with a reason after). The function
 * re-checks every rule, so a stale page can only fail.
 */
export type MarkAttendedState = { error: string } | { ok: string } | null;

export async function markAttended(_prev: MarkAttendedState, fd: FormData): Promise<MarkAttendedState> {
  const bookingId = String(fd.get("booking_id") ?? "").trim();
  const occurrenceId = String(fd.get("occurrence_id") ?? "").trim();
  const reason = String(fd.get("reason") ?? "").trim();
  if (!bookingId) return { error: "Something is missing. Try again." };
  const supabase = createClient();
  const { error } = await supabase.rpc("staff_mark_attended", {
    p_booking_id: bookingId, p_reason: reason || undefined,
  });
  if (error) {
    const c = error.code ?? "";
    if (c === "PT403") return { error: "Only owners and managers correct a finalised day." };
    if (c === "PT400") return { error: "Say why they are being marked attended." };
    if (c === "PT422") return { error: "They need to sign the studio waiver first." };
    return { error: error.message };
  }
  revalidatePath(`/roster/${occurrenceId}`);
  revalidatePath(`/instructor/roster/${occurrenceId}`);
  return { ok: "Marked attended." };
}

/**
 * Decision 35 (b) — Mark no-show from the roster. One path in the database,
 * staff_mark_no_show: a booked member, not checked in, once the class has
 * started; the coach or desk-up until the day is finalised, manager-up with a
 * reason after. It does what the finalisation sweep does for that one booking.
 */
export async function markNoShow(_prev: MarkAttendedState, fd: FormData): Promise<MarkAttendedState> {
  const bookingId = String(fd.get("booking_id") ?? "").trim();
  const occurrenceId = String(fd.get("occurrence_id") ?? "").trim();
  const reason = String(fd.get("reason") ?? "").trim();
  if (!bookingId) return { error: "Something is missing. Try again." };
  const supabase = createClient();
  const { error } = await supabase.rpc("staff_mark_no_show", {
    p_booking_id: bookingId, p_reason: reason || undefined,
  });
  if (error) {
    const c = error.code ?? "";
    if (c === "PT403") return { error: "Only owners and managers correct a finalised day." };
    if (c === "PT400") return { error: "Say why they are being marked a no-show." };
    if (c === "PT409") {
      if (/already a no-show/.test(error.message)) return { error: "They are already marked a no-show." };
      if (/checked in/.test(error.message)) return { error: "They are already checked in." };
      if (/not started/.test(error.message)) return { error: "The class has not started yet." };
      return { error: "Only a booked member can be marked a no-show." };
    }
    return { error: error.message };
  }
  revalidatePath(`/roster/${occurrenceId}`);
  revalidatePath(`/instructor/roster/${occurrenceId}`);
  return { ok: "Marked no-show." };
}
