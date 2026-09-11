"use server";

import { revalidatePath } from "next/cache";
import { getStaffContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export type ExcuseState = { ok: boolean; message: string } | null;

/**
 * Decision 24: excuse one. Front desk and up — §9 puts the desk at the counter
 * hearing the reason, and a rule only a manager can bend is one the desk works
 * around by not enforcing it.
 *
 * The function does the work and the audit row; this only turns its refusals
 * into sentences.
 */
export async function excuseInfraction(_prev: ExcuseState, fd: FormData): Promise<ExcuseState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const reason = String(fd.get("reason") ?? "").trim();
  if (!reason) return { ok: false, message: "Say why it is being excused." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("excuse_infraction", {
    p_infraction_id: String(fd.get("id") ?? ""),
    p_reason: reason,
  });
  if (error) {
    if (error.code === "PT403" || /PT403/.test(error.message)) {
      return { ok: false, message: "Your role cannot excuse these." };
    }
    if (error.code === "PT409" || /PT409/.test(error.message)) {
      return { ok: false, message: "That one has already been excused." };
    }
    return { ok: false, message: error.message };
  }

  revalidatePath("/members");
  const restored = (data as { allowance_restored?: boolean } | null)?.allowance_restored;
  return {
    ok: true,
    message: restored
      ? "Excused, and their peak class has been given back."
      : "Excused.",
  };
}
