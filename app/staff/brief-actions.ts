"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type BriefState = { error: string } | null;

/**
 * Mark one insight actioned or dismissed.
 *
 * Both feed §11's suppression window: the same subject and type will not come
 * back for seven days, whether the owner did the thing or decided it did not
 * need doing. Dismissing is a real answer, not a way of hiding from one.
 */
export async function setInsightStatus(_prev: BriefState, fd: FormData): Promise<BriefState> {
  const id = String(fd.get("id") ?? "");
  const status = String(fd.get("status") ?? "");
  if (status !== "actioned" && status !== "dismissed") {
    return { error: "An insight can only be actioned or dismissed." };
  }

  const supabase = createClient();
  const { error } = await supabase.rpc("set_insight_status", {
    p_insight_id: id,
    p_status: status,
  });
  if (error) {
    return error.code === "PT403"
      ? { error: "Only owners and managers can act on the brief." }
      : { error: error.message };
  }
  revalidatePath("/");
  return null;
}
