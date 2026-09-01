"use server";

import { revalidatePath } from "next/cache";
import { getStaffContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export type ExtendState = { ok: boolean; message: string } | null;

/**
 * Give a studio more time. Platform admin only — enforced in extend_trial(),
 * not here, because a check in a server action is a promise and a check in the
 * function is the rule.
 */
export async function extendTrial(_prev: ExtendState, fd: FormData): Promise<ExtendState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "Not signed in." };

  const supabase = createClient();
  const { error } = await supabase.rpc("extend_trial", {
    p_studio_id: String(fd.get("studio_id") ?? ""),
    p_days: Number(fd.get("days") ?? 14),
  });
  if (error) {
    return /PT403/.test(error.message)
      ? { ok: false, message: "Operators only." }
      : { ok: false, message: error.message };
  }
  revalidatePath("/admin/billing");
  return { ok: true, message: "Extended." };
}
