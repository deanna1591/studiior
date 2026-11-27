"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

/**
 * Decision 21 (g): bring back a class cancelled at its cut-off. The preview says
 * who comes back; the run restores the class, every released seat with its free
 * class, fee or credit cover, pins it to run for that date, and emails each
 * member once. The database re-checks every rule.
 */
export type RunAnywayPreview = {
  offered: boolean; reason: string | null;
  members: { booking_id: string; name: string; waitlisted: boolean }[];
};

const REASONS: Record<string, string> = {
  not_cancelled: "This class is not cancelled.",
  not_offered: "Only a class cancelled at its cut-off can be run anyway.",
  started: "This class has started.",
  slot_taken: "The room or the coach is taken at that time now.",
};

export async function runAnywayPreview(occurrenceId: string): Promise<RunAnywayPreview | { error: string }> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("run_anyway_preview", { p_occurrence_id: occurrenceId });
  if (error) return { error: error.code === "PT403" ? "Only owners and managers run a cancelled class." : error.message };
  return data as unknown as RunAnywayPreview;
}

export async function runCancelledClassAnyway(occurrenceId: string): Promise<{ ok: string } | { error: string }> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("run_cancelled_class_anyway", { p_occurrence_id: occurrenceId });
  if (error) return { error: error.code === "PT403" ? "Only owners and managers run a cancelled class." : error.message };
  const r = data as { ok: boolean; reason?: string; booked?: number; credit_spent?: string[] };
  if (!r?.ok) return { error: REASONS[r?.reason ?? ""] ?? "Could not run it." };
  revalidatePath("/schedule");
  revalidatePath("/schedule/flex");
  revalidatePath(`/roster/${occurrenceId}`);
  const n = r.booked ?? 0;
  const spent = (r.credit_spent ?? []).length
    ? ` ${r.credit_spent!.join(", ")} already spent the returned credit.` : "";
  return { ok: `It runs. ${n} ${n === 1 ? "member is" : "members are"} back in and emailed.${spent}` };
}
