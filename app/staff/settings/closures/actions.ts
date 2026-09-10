"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

export type ClosureResult =
  | { ok: false; requires_confirmation: true; starts_on: string; ends_on: string;
      partial: boolean; classes: number; members_booked: number;
      detail: { occurrence_id: string; name: string; local: string; booked: number }[] }
  | { ok: true; classes_cancelled: number; members_notified: number };

export type ClosureState = { error: string } | { result: ClosureResult } | null;
export type PlainState = { ok: boolean; message: string } | null;

const t = (fd: FormData, k: string) => String(fd.get(k) ?? "").trim();
const say = (m: string) =>
  /PT403/.test(m) ? "Only owners and managers close the studio."
  : /PT422|PT400/.test(m) ? m.replace(/^.*?:\s*/, "")
  : m;

async function run(fd: FormData, confirm: boolean): Promise<ClosureState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };
  const starts_on = t(fd, "starts_on");
  const ends_on = t(fd, "ends_on") || starts_on;
  if (!starts_on) return { error: "Pick the first day you are closed." };
  if (ends_on < starts_on) return { error: "The last day is before the first." };
  const reason = t(fd, "reason");
  if (!reason) return { error: "Say why — it is what a member sees instead of an empty day." };

  const partial = t(fd, "partial") === "on";
  const from = partial ? t(fd, "starts_at_time") : "";
  const to = partial ? t(fd, "ends_at_time") : "";
  if (partial && (!from || !to)) {
    return { error: "A part-day closure needs both a start and an end time." };
  }

  const supabase = createClient();
  const { data, error } = await supabase.rpc("close_studio", {
    p_studio_id: ctx.studioId,
    p_starts_on: starts_on, p_ends_on: ends_on, p_reason: reason,
    p_starts_at_time: from || undefined,
    p_ends_at_time: to || undefined,
    p_confirm: confirm,
  });
  if (error) return { error: say(error.message) };
  if (confirm) {
    revalidatePath("/settings/closures"); revalidatePath("/schedule"); revalidatePath("/");
  }
  return { result: data as unknown as ClosureResult };
}

/** Says what closing costs and changes nothing. */
export async function previewClosure(_prev: ClosureState, fd: FormData) {
  return run(fd, false);
}

/**
 * The second, deliberate press — and it re-runs rather than replaying.
 *
 * Between the two presses somebody may have booked into one of those classes,
 * and cancelling a stale list would miss them. The counts reported afterwards
 * are what actually happened.
 */
export async function applyClosure(_prev: ClosureState, fd: FormData) {
  return run(fd, true);
}

/**
 * Reopening is not an undo and the message says so.
 *
 * A cancelled class had its members told it was off; a studio changing its mind
 * cannot untell them. What comes back is the classes that were never made.
 */
export async function reopen(_prev: PlainState, fd: FormData): Promise<PlainState> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("reopen_studio", {
    p_closure_id: t(fd, "closure_id"),
  });
  if (error) return { ok: false, message: say(error.message) };
  const r = data as unknown as
    { reopened: string; classes_regenerated: number; still_cancelled: number };
  revalidatePath("/settings/closures"); revalidatePath("/schedule");
  const bits = [`Open again ${r.reopened}.`];
  if (r.classes_regenerated > 0) bits.push(`${r.classes_regenerated} classes put back on.`);
  if (r.still_cancelled > 0) {
    bits.push(
      `${r.still_cancelled} stay cancelled — those members were told they were off, ` +
      `so they are not resurrected. Add them back yourself if you want them.`);
  }
  return { ok: true, message: bits.join(" ") };
}
