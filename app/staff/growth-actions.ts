"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

/**
 * Decision 106 — applying a growth proposal, and raising a coach's budget. Both
 * go through RPCs that re-check manager-up in the database (PT403), so a stale
 * page can only fail, never act around the gate. Shaped to work from a
 * useFormState form (the dashboard card) and an imperative transition (the
 * Retention section) alike.
 */
export type GrowthState = { error: string } | { ok: true } | null;

function codeOf(err: { code?: string; message?: string } | null): string {
  return err?.code ?? (/(PT\d\d\d)/.exec(err?.message ?? "")?.[1] ?? "");
}

export async function applyGrowthTier(_prev: GrowthState, fd: FormData): Promise<GrowthState> {
  const occId = String(fd.get("occurrence_id") ?? "").trim();
  const tier = String(fd.get("tier") ?? "").trim();
  const scope = String(fd.get("scope") ?? "week").trim();
  if (!occId || (tier !== "core" && tier !== "flex") || (scope !== "week" && scope !== "series")) {
    return { error: "Something’s missing — try again." };
  }
  const supabase = createClient();
  const { error } = await supabase.rpc("growth_apply", {
    p_occurrence_id: occId, p_tier: tier, p_scope: scope,
  });
  if (error) {
    const c = codeOf(error);
    if (c === "PT403") return { error: "Only owners and managers change the timetable." };
    if (c === "PT409") return { error: "That class is a one-off, so there is no series to change." };
    return { error: error.message };
  }
  revalidatePath("/");
  revalidatePath("/retention");
  return { ok: true };
}

export async function raiseInstructorBudget(_prev: GrowthState, fd: FormData): Promise<GrowthState> {
  const instructorId = String(fd.get("instructor_id") ?? "").trim();
  const n = Number.parseInt(String(fd.get("n") ?? ""), 10);
  if (!instructorId || !Number.isFinite(n)) return { error: "Something’s missing — try again." };
  const supabase = createClient();
  const { error } = await supabase.rpc("set_instructor_core_budget", {
    p_instructor_id: instructorId, p_n: n,
  });
  if (error) {
    const c = codeOf(error);
    if (c === "PT403") return { error: "Only owners and managers set a budget." };
    if (c === "PT422") return { error: "The budget is a number from 1 to 3." };
    return { error: error.message };
  }
  revalidatePath("/");
  revalidatePath("/retention");
  revalidatePath(`/instructors/${instructorId}`);
  return { ok: true };
}
