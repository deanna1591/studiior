"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

export type PublishState = { ok: false; message: string } | null;

/**
 * Decision 25. One call; the database publishes, records the holes, emails
 * each instructor their own classes and names anybody it could not reach.
 * Publishing twice is a no-op there, so a double press sends nothing.
 */
export async function publishMonth(_prev: PublishState, fd: FormData): Promise<PublishState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const month = String(fd.get("month") ?? "");
  if (!/^\d{4}-\d{2}-01$/.test(month)) return { ok: false, message: "That is not a month." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("publish_month", {
    p_studio_id: ctx.studioId, p_month: month,
  });
  if (error) return { ok: false, message: error.message };

  const r = data as unknown as { month: string };
  revalidatePath("/publish");
  revalidatePath("/");
  // Back to the month that was just published, not to whichever draft the
  // page would pick next: the first version selected November the moment
  // October went out, and the success line sat above "Publish November".
  // What happened is rendered from the facts on the way back in.
  redirect(`/publish?m=${r.month.slice(0, 7)}&just=1`);
}

/**
 * The studio records a yes given some other way — a text, a word at the desk.
 * confirm_month_roster() allows manager-up on the instructor's behalf, the
 * same as confirm_week() does, and audits who did it.
 */
export async function confirmRosterFor(fd: FormData): Promise<void> {
  const ctx = await getStaffContext();
  if (!ctx) return;
  const month = String(fd.get("month") ?? "");
  const instructor = String(fd.get("instructor_id") ?? "");
  const supabase = createClient();
  const { error } = await supabase.rpc("confirm_month_roster", {
    p_instructor_id: instructor, p_month: month,
  });
  revalidatePath("/publish");
  redirect(`/publish?m=${month.slice(0, 7)}${error ? `&err=${encodeURIComponent(error.message)}` : ""}`);
}
