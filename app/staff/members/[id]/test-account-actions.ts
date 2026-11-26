"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

/**
 * Decision 97 (b): mark (or unmark) a member as a test account. Manager-up and
 * audited in the RPC; this is the thin wrapper the profile switch calls.
 */
export async function setTestAccount(memberId: string, on: boolean): Promise<{ ok: true } | { error: string }> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("set_member_test_account", { p_member_id: memberId, p_on: on });
  if (error) return { error: error.message };
  if (!(data as { ok?: boolean } | null)?.ok) return { error: "Could not update the test account switch." };
  revalidatePath("/members/[id]", "page");
  revalidatePath("/members");
  return { ok: true };
}
