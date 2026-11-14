"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

/**
 * Decision 103a — waive (or restore) the reservation fee for one member.
 * Manager-up is enforced in the RPC; this is the thin wrapper the profile
 * switch calls. On waive, the member's open free bookings are grandfathered and
 * any unsent due email is withdrawn.
 */
export async function setReservationFeeWaiver(
  memberId: string,
  on: boolean,
  note: string | null
): Promise<{ ok: true } | { error: string }> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("staff_set_reservation_fee_waiver", {
    p_member_id: memberId,
    p_on: on,
    p_note: note && note.trim() ? note.trim() : undefined,
  });
  if (error) return { error: error.message };
  const r = data as { ok?: boolean } | null;
  if (!r?.ok) return { error: "Could not update the reservation fee waiver." };
  revalidatePath("/members/[id]", "page");
  revalidatePath("/members");
  return { ok: true };
}
