"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

/**
 * Decision 106 — a manager sets a coach's "Core classes per week" budget (1..21).
 * The RPC re-checks manager-up (PT403) and the range (PT422); a stale page can
 * only fail, never act around the gate.
 */
export type BudgetState = { ok: boolean; message: string } | null;

export async function saveBudget(_prev: BudgetState, fd: FormData): Promise<BudgetState> {
  const instructorId = String(fd.get("instructor_id") ?? "").trim();
  const n = Number.parseInt(String(fd.get("n") ?? ""), 10);
  if (!instructorId) return { ok: false, message: "No instructor." };
  if (!Number.isFinite(n) || n < 1 || n > 21) {
    return { ok: false, message: "Pick a number from 1 to 21." };
  }
  const supabase = createClient();
  const { data, error } = await supabase.rpc("set_instructor_core_budget", {
    p_instructor_id: instructorId, p_n: n,
  });
  if (error) {
    if ((error.code ?? "") === "PT403") return { ok: false, message: "Only owners and managers set a budget." };
    return { ok: false, message: error.message };
  }
  if (!(data as { ok?: boolean })?.ok) return { ok: false, message: "Nothing was saved." };
  revalidatePath(`/instructors/${instructorId}`);
  return { ok: true, message: `Saved. ${n} core ${n === 1 ? "class" : "classes"} per week.` };
}
