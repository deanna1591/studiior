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

/**
 * Decision 22's switches and the per-tier settings they gate.
 *
 * Eleven columns that had a default and nowhere to change it — the same shape as
 * the occurrence horizon, which is why one studio was carrying 1,421 open
 * classes nobody had agreed to teach. Off by default, so a studio that never
 * opens this panel sees no change anywhere.
 */
export async function saveGuarantees(_prev: PlainState, fd: FormData): Promise<PlainState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const on = (k: string) => String(fd.get(k) ?? "") === "on";
  const int = (k: string) => Number(String(fd.get(k) ?? ""));
  // Money is entered in whole units and stored in cents. Never floats, and
  // rounded once here rather than in three places downstream.
  const cents = (k: string) => Math.round(Number(String(fd.get(k) ?? "")) * 100);

  const guarantees = on("guarantees_enabled");
  const flex = on("flex_enabled");
  const coreMin = int("core_min_bookings");
  const coreCut = int("core_cutoff_hours");
  const corePct = int("core_unmet_pay_pct");
  const flexMin = int("flex_min_bookings");
  const mode = String(fd.get("flex_deadline_mode") ?? "previous_day_at");
  const flexTime = String(fd.get("flex_deadline_time") ?? "20:00");
  const flexHours = int("flex_deadline_hours");
  const unmet = cents("flex_unmet_pay");
  const standby = cents("flex_standby_pay");
  const adjacency = int("adjacency_minutes");

  const bad =
    !Number.isFinite(coreMin) || coreMin < 0 ? "A core minimum cannot be negative."
    : !Number.isFinite(coreCut) || coreCut < 0 ? "A cutoff cannot be negative."
    : !Number.isFinite(corePct) || corePct < 0 || corePct > 100
      ? "The holding rate is a percentage between 0 and 100."
    : !Number.isFinite(flexMin) || flexMin < 0 ? "A flex minimum cannot be negative."
    : mode === "hours_before" && (!Number.isFinite(flexHours) || flexHours < 0)
      ? "A flex cutoff in hours cannot be negative."
    : mode === "previous_day_at" && !/^\d{2}:\d{2}/.test(flexTime)
      ? "Pick the time of day the flex cutoff falls."
    : !Number.isFinite(unmet) || unmet < 0 ? "Unmet pay cannot be negative."
    : !Number.isFinite(standby) || standby < 0 ? "Standby pay cannot be negative."
    : !Number.isFinite(adjacency) || adjacency < 0 || adjacency > 1440
      ? "Adjacency is a gap in minutes, up to a day."
    : null;
  if (bad) return { ok: false, message: bad };

  const supabase = createClient();
  const { data, error } = await supabase.from("studio_settings")
    .update({
      guarantees_enabled: guarantees,
      flex_enabled: flex,
      core_min_bookings: Math.floor(coreMin),
      core_cutoff_hours: Math.floor(coreCut),
      core_unmet_pay_pct: Math.floor(corePct),
      flex_min_bookings: Math.floor(flexMin),
      flex_deadline_mode: mode,
      flex_deadline_time: `${flexTime.slice(0, 5)}:00`,
      flex_deadline_hours: Math.floor(Number.isFinite(flexHours) ? flexHours : 12),
      flex_unmet_pay_cents: unmet,
      flex_standby_pay_cents: standby,
      adjacency_minutes: Math.floor(adjacency),
    })
    .eq("studio_id", ctx.studioId).select("studio_id");
  if (error) return { ok: false, message: error.message };
  if (!data?.length) {
    return { ok: false, message: "Nothing was saved. Owners and managers only." };
  }
  revalidatePath("/settings"); revalidatePath("/schedule"); revalidatePath("/series");
  return {
    ok: true,
    message: !guarantees && !flex
      ? "Saved. Both switches are off, so no class is evaluated and nothing is owed for one not running."
      : "Saved.",
  };
}
