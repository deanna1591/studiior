"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

export type HorizonResult =
  | { ok: true; days: number; cutoff: string; deleted: number; created: number;
      kept_edited: number; kept_manual: number; furthest_now: string | null }
  | { ok: false; requires_confirmation: true; days: number; cutoff: string;
      scheduled_now: number; furthest_now: string | null; will_delete: number;
      kept_edited: number; kept_manual: number }
  | { ok: false; reason: "members_booked_beyond_horizon"; days: number; cutoff: string;
      hint: string; blocked: { occurrence_id: string; name: string; local: string; booked: number }[] };

export type SettingsState = { error: string } | { result: HorizonResult } | null;

const say = (m: string) =>
  /PT403/.test(m) ? "Only owners and managers change how far ahead the timetable runs."
  : /PT422/.test(m) ? m.replace(/^.*?:\s*/, "")
  : m;

async function horizon(fd: FormData, confirm: boolean): Promise<SettingsState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };
  const days = Number(String(fd.get("days") ?? "").trim());
  if (!Number.isFinite(days)) return { error: "Give a number of days." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("set_occurrence_horizon", {
    p_studio_id: ctx.studioId, p_days: Math.floor(days), p_confirm: confirm,
  });
  if (error) return { error: say(error.message) };
  if (confirm) {
    revalidatePath("/settings"); revalidatePath("/schedule"); revalidatePath("/");
  }
  return { result: data as unknown as HorizonResult };
}

/** Says what it would remove and writes nothing. */
export async function previewHorizon(_prev: SettingsState, fd: FormData) {
  return horizon(fd, false);
}

/**
 * The second, deliberate press — and it re-runs rather than replaying.
 *
 * Between the two presses somebody may have booked a class the preview said was
 * empty, and deleting it then would be exactly the silent loss the refusal
 * exists to prevent.
 */
export async function applyHorizon(_prev: SettingsState, fd: FormData) {
  return horizon(fd, true);
}

export type PlainState = { ok: boolean; message: string } | null;

/**
 * The two timing settings migrations 066 and 067 added, which had the same
 * problem this screen exists to fix: a column with a default and nowhere to
 * change it.
 */
export async function saveTiming(_prev: PlainState, fd: FormData): Promise<PlainState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const due = Number(String(fd.get("availability_due_day") ?? ""));
  const esc = Number(String(fd.get("week_confirm_escalate_days") ?? ""));
  if (!Number.isFinite(due) || due < 1 || due > 28) {
    return { ok: false, message: "The due day has to be between 1 and 28 — February has to have it too." };
  }
  if (!Number.isFinite(esc) || esc < 1 || esc > 14) {
    return { ok: false, message: "The escalation window has to be between 1 and 14 days." };
  }

  const supabase = createClient();
  // A refused UPDATE returns no rows rather than an error, so "saved" with
  // nothing written is the failure to guard against.
  const { data, error } = await supabase.from("studio_settings")
    .update({
      availability_due_day: Math.floor(due),
      week_confirm_escalate_days: Math.floor(esc),
    })
    .eq("studio_id", ctx.studioId).select("studio_id");
  if (error) return { ok: false, message: error.message };
  if (!data?.length) {
    return { ok: false, message: "Nothing was saved. Owners and managers only." };
  }
  revalidatePath("/settings"); revalidatePath("/availability");
  return { ok: true, message: "Saved." };
}
