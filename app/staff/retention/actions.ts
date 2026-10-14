"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

// Decision 78 — a human has reached out, or decided not to. Both go through the
// role-checked RPCs; the page is manager-up (or a routed front desk), so a
// refusal only happens on a stale page and simply leaves the row as it was.
export async function markContacted(fd: FormData): Promise<void> {
  const id = String(fd.get("task_id") ?? "");
  if (!id) return;
  const supabase = createClient();
  await supabase.rpc("mark_task_contacted", { p_task_id: id });
  revalidatePath("/retention");
  revalidatePath("/");
}

export async function dismissRetentionTask(fd: FormData): Promise<void> {
  const id = String(fd.get("task_id") ?? "");
  if (!id) return;
  const supabase = createClient();
  await supabase.rpc("dismiss_task", { p_task_id: id });
  revalidatePath("/retention");
  revalidatePath("/");
}
