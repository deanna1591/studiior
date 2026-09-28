"use server";

import { createClient } from "@/lib/supabase/server";

/** Read the member's own purchase status (RLS: xpur_member_self). Used by the
 *  poll screen to wait for the callback to flip a pending purchase. */
export async function purchaseStatus(id: string): Promise<string | null> {
  const supabase = createClient();
  const { data } = await supabase
    .from("xendit_purchases").select("status").eq("id", id).maybeSingle();
  return data?.status ?? null;
}
