"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type FlexState = { ok: boolean; message: string } | null;

/** "This one runs whatever happens" — a real decision on a quiet week. */
export async function guarantee(_prev: FlexState, fd: FormData): Promise<FlexState> {
  const supabase = createClient();
  const { error } = await supabase.rpc("set_occurrence_guaranteed", {
    p_occurrence_id: String(fd.get("occurrence_id") ?? ""),
  });
  if (error) {
    return { ok: false, message: /PT403/.test(error.message)
      ? "Only owners and managers change the timetable." : error.message };
  }
  revalidatePath("/schedule/flex"); revalidatePath("/schedule");
  return { ok: true, message: "That one runs whatever happens now." };
}
