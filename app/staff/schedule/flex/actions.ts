"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type FlexState = { ok: boolean; message: string } | null;

/**
 * Decision 21 amendment — "Run it anyway" is now the reversible "Runs regardless"
 * switch: set_occurrence_always_runs sets the occurrence guarantee_tier to always
 * (the flex flag and minimum are untouched, so it can go back to flex). The older
 * set_occurrence_guaranteed stays in place, unchanged, for other callers.
 */
export async function guarantee(_prev: FlexState, fd: FormData): Promise<FlexState> {
  const supabase = createClient();
  const { error } = await supabase.rpc("set_occurrence_always_runs", {
    p_occurrence_id: String(fd.get("occurrence_id") ?? ""), p_on: true,
  });
  if (error) {
    const m = error.message;
    return { ok: false, message: /PT403/.test(m)
      ? "Only owners and managers change the timetable."
      : /PT409/.test(m) ? "Decided at the cut-off — this class can no longer be changed." : m };
  }
  revalidatePath("/schedule/flex"); revalidatePath("/schedule");
  return { ok: true, message: "That one runs regardless of bookings now." };
}
