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

/**
 * Decision 24: the seat-cap switch.
 *
 * One checkbox and nothing else — the caps themselves are per plan. Turning it
 * off does NOT clear the plans' numbers: a studio that switches off for a month
 * and back on should find its configuration where it left it, and wiping a
 * dozen carefully chosen limits because somebody unticked a box would be the
 * expensive kind of tidy.
 */
export async function saveSeatCaps(_prev: PlainState, fd: FormData): Promise<PlainState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const on = String(fd.get("seat_caps_enabled") ?? "") === "on";

  const supabase = createClient();
  const { data, error } = await supabase.from("studio_settings")
    .update({ seat_caps_enabled: on })
    .eq("studio_id", ctx.studioId).select("studio_id");
  if (error) return { ok: false, message: error.message };
  // A refused UPDATE does not raise — the row simply goes invisible and
  // PostgREST answers 200 with an empty array.
  if (!data?.length) {
    return { ok: false, message: "Nothing was saved. Owners and managers only." };
  }

  revalidatePath("/settings"); revalidatePath("/plans");
  return {
    ok: true,
    message: on
      ? "Saved. Set a limit on each plan that needs one — the rest stay unlimited."
      : "Saved. Limits are no longer applied, and the numbers on your plans are untouched.",
  };
}

/**
 * Decision 24's peak switch. One checkbox; the windows are their own form, and
 * the allowances live on each plan.
 */
export async function savePeakSwitch(_prev: PlainState, fd: FormData): Promise<PlainState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const on = String(fd.get("peak_allowance_enabled") ?? "") === "on";

  const supabase = createClient();
  const { data, error } = await supabase.from("studio_settings")
    .update({ peak_allowance_enabled: on })
    .eq("studio_id", ctx.studioId).select("studio_id");
  if (error) return { ok: false, message: error.message };
  if (!data?.length) return { ok: false, message: "Nothing was saved. Owners and managers only." };

  revalidatePath("/settings"); revalidatePath("/plans");
  return {
    ok: true,
    message: on
      ? "Saved. Mark your busy hours below, then set an allowance on an unlimited plan."
      : "Saved. Peak hours are no longer applied, and the windows you drew are untouched.",
  };
}

/**
 * Add a window, optionally to every day at once — which is the normal case. A
 * studio's rush hours are the same Monday to Friday and typing them seven times
 * is how somebody decides not to bother, the same argument as the availability
 * editor's copy-to-days.
 */
export async function addPeakWindow(_prev: PlainState, fd: FormData): Promise<PlainState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const from = String(fd.get("starts_at") ?? "").slice(0, 5);
  const to = String(fd.get("ends_at") ?? "").slice(0, 5);
  if (!/^\d{2}:\d{2}$/.test(from) || !/^\d{2}:\d{2}$/.test(to)) {
    return { ok: false, message: "Give a start and an end time." };
  }
  if (to <= from) {
    return { ok: false, message: "A window has to end after it starts. Hours that run past midnight are two windows, one on each day." };
  }

  const every = String(fd.get("every_day") ?? "") === "on";
  const one = Number(String(fd.get("day_of_week") ?? "1"));
  const days = every ? [0, 1, 2, 3, 4, 5, 6] : [one];
  if (days.some((d) => !Number.isInteger(d) || d < 0 || d > 6)) {
    return { ok: false, message: "Pick a day." };
  }

  const supabase = createClient();
  const { error } = await supabase.from("peak_windows").insert(
    days.map((d) => ({
      studio_id: ctx.studioId, day_of_week: d,
      starts_at: `${from}:00`, ends_at: `${to}:00`,
    })),
  );
  if (error) {
    // The unique index, which exists to stop a double-clicked form rather than
    // to stop a studio having two windows in a day.
    if (error.code === "23505") {
      return { ok: false, message: "That window is already there." };
    }
    if (/row-level security/i.test(error.message) || error.code === "42501") {
      return { ok: false, message: "Only owners and managers set peak hours." };
    }
    return { ok: false, message: error.message };
  }
  revalidatePath("/settings");
  return { ok: true, message: "Added." };
}

export async function removePeakWindow(fd: FormData) {
  const ctx = await getStaffContext();
  if (!ctx) return;
  const supabase = createClient();
  await supabase.from("peak_windows").delete()
    .eq("id", String(fd.get("id") ?? "")).eq("studio_id", ctx.studioId);
  revalidatePath("/settings");
}

/**
 * Decision 24's suspension ladder and the peak reminder's lead time.
 *
 * Every number the ladder uses is here. The CHECK in migration 108 refuses a
 * ladder that does not make sense — suspending before warning, a window of nought
 * — and its message is a constraint name, so the sane cases are caught here and
 * the constraint stays as the wall behind them.
 */
export async function saveSuspension(_prev: PlainState, fd: FormData): Promise<PlainState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const on = String(fd.get("suspension_enabled") ?? "") === "on";
  const int = (k: string) => Number(String(fd.get(k) ?? ""));
  const window_ = int("suspension_window_days");
  const warn = int("suspension_warn_at");
  const at = int("suspension_at");
  const days = int("suspension_days");
  const repeat = int("suspension_repeat_days");
  const lead = int("peak_cutoff_reminder_minutes");

  const bad =
    !Number.isFinite(lead) || lead < 0 || lead > 2880
      ? "The reminder is a number of minutes, up to two days. Nought switches it off."
    : !on ? null
    : !Number.isFinite(window_) || window_ < 1 || window_ > 365
      ? "The window is a number of days, up to a year."
    : !Number.isFinite(warn) || warn < 1 ? "Warn at the first infraction or later."
    : !Number.isFinite(at) || at <= warn
      ? "Suspending has to come after warning, or the warning never happens."
    : !Number.isFinite(days) || days < 1 || days > 365
      ? "A suspension lasts between a day and a year."
    : !Number.isFinite(repeat) || repeat < 1 || repeat > 365
      ? "A repeat suspension lasts between a day and a year."
    : null;
  if (bad) return { ok: false, message: bad };

  const supabase = createClient();
  const { data, error } = await supabase.from("studio_settings")
    .update({
      suspension_enabled: on,
      peak_cutoff_reminder_minutes: Math.floor(lead),
      ...(on
        ? {
            suspension_window_days: Math.floor(window_),
            suspension_warn_at: Math.floor(warn),
            suspension_at: Math.floor(at),
            suspension_days: Math.floor(days),
            suspension_repeat_days: Math.floor(repeat),
          }
        : {}),
    })
    .eq("studio_id", ctx.studioId).select("studio_id");
  if (error) return { ok: false, message: error.message };
  if (!data?.length) return { ok: false, message: "Nothing was saved. Owners and managers only." };

  revalidatePath("/settings"); revalidatePath("/members");
  return {
    ok: true,
    message: on
      ? "Saved. Absentees will be marked from now on, and nothing reaches back into history."
      : "Saved. Nobody is suspended and no new infractions are recorded. The ones already on file are kept.",
  };
}

/**
 * Decision 25. The switch goes through set_publication_enabled() rather than a
 * plain UPDATE, because turning it on has to publish this month and any month
 * members have already booked into AT ONCE — hiding those would be the
 * "unpublish" this feature refuses to offer, arriving by the back door. The
 * function says what it published and the message repeats it.
 */
export async function savePublication(_prev: PlainState, fd: FormData): Promise<PlainState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const on = String(fd.get("publication_enabled") ?? "") === "on";

  const supabase = createClient();
  const { data, error } = await supabase.rpc("set_publication_enabled", {
    p_studio_id: ctx.studioId, p_enabled: on,
  });
  if (error) return { ok: false, message: error.message };

  const r = data as { enabled: boolean; auto_published: { label: string; why: string }[] } | null;
  const auto = r?.auto_published ?? [];
  revalidatePath("/settings");
  revalidatePath("/publish");
  revalidatePath("/", "layout");
  if (!on) return { ok: true, message: "Publication is off. Every month is live as soon as it is made, as before." };
  if (auto.length === 0) {
    return { ok: true, message: "Publication is on. Nothing is published yet — members cannot book until you publish a month." };
  }
  return {
    ok: true,
    message: "Publication is on. Published straight away: " +
      auto.map((m) => `${m.label} (${m.why})`).join("; ") +
      ". Nothing was emailed for those — instructors have had them on their schedule all along.",
  };
}
