"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

/**
 * Decision 103 (n): staff choose how a free first class's fee is paid on a seat
 * already booked (Pays at the studio or Waive), and the desk or the coach
 * records it with Paid at studio. The database re-checks every rule.
 */
export type FeeActionState = { error: string } | { ok: string } | null;

const REASONS: Record<string, string> = {
  not_due: "This seat's fee is already settled.",
  not_booked: "That booking is no longer booked.",
  unknown_choice: "Choose Pays at the studio or Waive.",
  not_pay_at_studio: "This seat is not marked to pay at the studio.",
  already_paid: "The fee is already recorded.",
  unknown_method: "Choose how they paid.",
  no_fee: "This studio has no reservation fee.",
};

function refresh(occurrenceId: string) {
  revalidatePath(`/roster/${occurrenceId}`);
  revalidatePath(`/instructor/roster/${occurrenceId}`);
}

export async function setSeatFeeChoice(_p: FeeActionState, fd: FormData): Promise<FeeActionState> {
  const bookingId = String(fd.get("booking_id") ?? "");
  const occurrenceId = String(fd.get("occurrence_id") ?? "");
  const choice = String(fd.get("choice") ?? "");
  const supabase = createClient();
  const { data, error } = await supabase.rpc("set_free_fee_choice", {
    p_booking_id: bookingId, p_choice: choice, p_note: undefined,
  });
  if (error) return { error: error.code === "PT403" ? "Only the studio sets how the fee is paid." : error.message };
  const r = data as { ok: boolean; reason?: string };
  if (!r?.ok) return { error: REASONS[r?.reason ?? ""] ?? "Could not save that." };
  refresh(occurrenceId);
  return { ok: choice === "studio" ? "Marked to pay at the studio." : "Fee waived." };
}

export async function recordPaidAtStudio(_p: FeeActionState, fd: FormData): Promise<FeeActionState> {
  const bookingId = String(fd.get("booking_id") ?? "");
  const occurrenceId = String(fd.get("occurrence_id") ?? "");
  const method = String(fd.get("method") ?? "");
  const reference = String(fd.get("reference") ?? "").trim();
  const supabase = createClient();
  const { data, error } = await supabase.rpc("record_reservation_paid_at_studio", {
    p_booking_id: bookingId, p_method: method, p_reference: reference || undefined,
  });
  if (error) return { error: error.code === "PT403" ? "That is not your class." : error.message };
  const r = data as { ok: boolean; reason?: string };
  if (!r?.ok) return { error: REASONS[r?.reason ?? ""] ?? "Could not record that." };
  refresh(occurrenceId);
  return { ok: "Paid at studio. Recorded." };
}
