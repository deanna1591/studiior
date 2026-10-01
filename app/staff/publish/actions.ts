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

/**
 * G — carry a silent instructor's roster into the selected month now, rather
 * than waiting for the nightly sweep. carry_forward_roster() is manager-up and
 * idempotent; the report of what did and did not carry is on the page from the
 * preview, so this only has to do it and come back.
 */
export async function carryForwardNow(fd: FormData): Promise<void> {
  const ctx = await getStaffContext();
  if (!ctx) return;
  const month = String(fd.get("month") ?? "");
  if (!/^\d{4}-\d{2}-01$/.test(month)) return;

  const supabase = createClient();
  const { error } = await supabase.rpc("carry_forward_roster", { p_studio_id: ctx.studioId, p_month: month });
  revalidatePath("/publish");
  revalidatePath("/schedule");
  revalidatePath("/");
  redirect(`/publish?m=${month.slice(0, 7)}${error ? `&err=${encodeURIComponent(error.message)}` : "&carried=1"}`);
}

// Decision 42a — clear every instructor assignment in a month. Refused (PT409)
// only when the month is published AND members have booked into it.
export async function clearMonthAssignments(fd: FormData): Promise<void> {
  const ctx = await getStaffContext();
  if (!ctx) redirect("/login");
  const month = String(fd.get("month") ?? "");
  const clearTemplates = String(fd.get("clear_templates") ?? "") === "on";
  // Decision 42a amendment: on a published month with bookings the owner must
  // tick an acknowledgement. The tick arrives as "on"; the database still
  // enforces owner + acknowledge, so a forged field changes nothing.
  const acknowledge = String(fd.get("acknowledge") ?? "") === "on";
  const supabase = createClient();
  const { data, error } = await supabase.rpc("clear_month_assignments", {
    p_studio_id: ctx.studioId, p_month: month, p_clear_templates: clearTemplates,
    p_acknowledge: acknowledge,
  });
  if (error) {
    const msg = /PT409/.test(error.message)
      ? "This month is published and members have booked into it — change assignments class by class from the Schedule instead."
      : error.message;
    redirect(`/publish?m=${month.slice(0, 7)}&err=${encodeURIComponent(msg)}`);
  }
  const r = data as unknown as { cleared: number; templates_cleared: number };
  redirect(`/publish?m=${month.slice(0, 7)}&cleared_n=${r?.cleared ?? 0}&tpl=${r?.templates_cleared ?? 0}`);
}
