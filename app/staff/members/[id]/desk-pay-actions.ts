"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

/**
 * Decision 73 (c) — restore pay at the desk for a member whose desk pay was
 * turned off by a no-show or late cancellation. Manager-up is enforced in the
 * RPC; this is a thin wrapper the profile button calls.
 */
export async function restoreDeskPay(memberId: string): Promise<{ ok: true } | { error: string }> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("restore_desk_pay", { p_member_id: memberId });
  if (error) return { error: error.message };
  const r = data as { ok?: boolean } | null;
  if (!r?.ok) return { error: "Could not restore pay at the desk." };
  revalidatePath("/members/[id]", "page");
  revalidatePath("/members");
  return { ok: true };
}
