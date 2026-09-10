"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { getStaffContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import type { EditResult } from "./actions";

/**
 * Archive, end, restore and delete a series.
 *
 * WHY DELETE IS THE SMALLEST BUTTON HERE. `class_occurrences.series_id` is ON
 * DELETE CASCADE, and RLS has always let a manager issue the delete through
 * PostgREST. Reproduced on the seeded Mat Pilates series before migration 078
 * was written: DELETE 1, no error, and 35 occurrences, 84 bookings and 63
 * check-ins gone with it. The guard is in the database; this screen only has to
 * stop offering it as though it were ordinary.
 */

export type LifecycleState =
  | { ok: true; message: string }
  | { ok: false; message: string }
  | { ok: false; confirm: "archive" | "delete"; message: string }
  | { ok: false; message: string; blocked: { local: string; booked: number }[] }
  | null;

const say = (m: string) =>
  /PT403/.test(m) ? "Only owners and managers change the timetable."
  : /PT404/.test(m) ? "That series no longer exists."
  : /PT409|PT422/.test(m) ? m.replace(/^.*?:\s*/, "")
  : m;

const refresh = () => {
  revalidatePath("/series");
  revalidatePath("/schedule");
  revalidatePath("/");
};

/** The database composes the sentence; this only decides which press it was. */
export async function archiveSeries(_prev: LifecycleState, fd: FormData): Promise<LifecycleState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const id = String(fd.get("id") ?? "");
  const confirmed = String(fd.get("confirm") ?? "") === "1";

  const supabase = createClient();
  const { data, error } = await supabase.rpc("archive_series", {
    p_series_id: id, p_confirm: confirmed,
  });
  if (error) return { ok: false, message: say(error.message) };

  const r = data as unknown as {
    confirm_required?: boolean; archive?: { effect?: string };
    removed_future?: number; kept_booked?: number; note?: string | null;
  };

  if (r?.confirm_required) {
    return { ok: false, confirm: "archive",
             message: `${r.archive?.effect ?? "This will archive the series."} Archive it?` };
  }

  refresh();
  const removed = r?.removed_future ?? 0;
  return {
    ok: true,
    message: `Archived. ${removed} future class${removed === 1 ? "" : "es"} removed.`
      + (r?.note ? ` ${r.note}` : ""),
  };
}

export async function restoreSeries(_prev: LifecycleState, fd: FormData): Promise<LifecycleState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("restore_series", {
    p_series_id: String(fd.get("id") ?? ""),
  });
  if (error) return { ok: false, message: say(error.message) };

  refresh();
  const r = data as unknown as { regenerated?: number; note?: string };
  return {
    ok: true,
    message: `Restored. ${r?.regenerated ?? 0} class${r?.regenerated === 1 ? "" : "es"} back on the calendar.`
      + (r?.note ? ` ${r.note}` : ""),
  };
}

/**
 * End it on a date, through end_series() -> update_series().
 *
 * That is the only path that reconciles a changed rule with the classes already
 * on the calendar, and the only one that refuses rather than quietly taking a
 * class away from somebody who is booked on it.
 */
export async function endSeries(_prev: LifecycleState, fd: FormData): Promise<LifecycleState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const ends_on = String(fd.get("end_on_date") ?? "").trim();
  if (!ends_on) return { ok: false, message: "Pick the last day this series runs." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("end_series", {
    p_series_id: String(fd.get("id") ?? ""),
    p_ends_on: ends_on,
    p_confirm: String(fd.get("confirm") ?? "") === "1",
  });
  if (error) return { ok: false, message: say(error.message) };

  const r = data as unknown as EditResult & { ended_on?: string };

  if ("reason" in r && r.reason === "members_booked_on_dropped_classes") {
    return {
      ok: false,
      message: "Some of the classes after that date have members booked. "
             + "Ending the series would take their class away, so it is refused. "
             + "Cancel those classes from the schedule first, or end it later.",
      blocked: r.blocked.map((b) => ({ local: b.local, booked: b.booked })),
    };
  }
  if ("requires_confirmation" in r && r.requires_confirmation) {
    return {
      ok: false, confirm: "archive",
      message: `Ending it on ${ends_on} cancels ${r.will_cancel} class`
             + `${r.will_cancel === 1 ? "" : "es"} after that date`
             + (r.members_emailed ? `, and emails ${r.members_emailed} member${r.members_emailed === 1 ? "" : "s"}` : "")
             + ". End it?",
    };
  }

  refresh();
  const ok = r as Extract<EditResult, { ok: true }>;
  return {
    ok: true,
    message: `Ends on ${r.ended_on ?? ends_on}. ${ok.cancelled ?? 0} class`
           + `${ok.cancelled === 1 ? "" : "es"} after that date cancelled. `
           + "Everything it already taught keeps its place.",
  };
}

/**
 * Delete. Two presses, and the database refuses the first one outright whenever
 * anything has run or anyone has booked — naming what is in the way.
 */
export async function deleteSeries(_prev: LifecycleState, fd: FormData): Promise<LifecycleState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const id = String(fd.get("id") ?? "");
  const confirmed = String(fd.get("confirm") ?? "") === "1";

  const supabase = createClient();

  if (!confirmed) {
    const { data, error } = await supabase.rpc("series_impact", { p_series_id: id });
    if (error) return { ok: false, message: say(error.message) };
    const r = data as unknown as { delete?: { allowed?: boolean; effect?: string } };
    if (!r?.delete?.allowed) {
      return { ok: false, message: r?.delete?.effect ?? "This series cannot be deleted." };
    }
    return { ok: false, confirm: "delete", message: `${r.delete.effect} Delete it?` };
  }

  // The guard in the database is the boundary; this DELETE goes through RLS the
  // same as any other. A refused delete does not raise — it changes nothing —
  // so the row count is checked rather than only the error.
  const { data, error } = await supabase.from("class_series")
    .delete().eq("id", id).select("id");
  if (error) return { ok: false, message: say(error.message) };
  if (!data || data.length === 0) {
    return { ok: false, message: "Nothing was deleted. Your role may not change the timetable." };
  }

  refresh();
  redirect("/series");
}

/**
 * The guarantee tier, per series.
 *
 * Its own writer, deliberately: `update_series()` takes every field as a
 * parameter and adding two more would change its signature, and migration 080's
 * `set_series_guarantee()` also reaches the classes already on the calendar — a
 * studio that changes a tier and finds nothing different for sixty days has been
 * given a setting that does nothing.
 */
export async function setSeriesTier(_prev: LifecycleState, fd: FormData): Promise<LifecycleState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const tier = String(fd.get("tier") ?? "core") as "core" | "flex" | "always";
  const raw = String(fd.get("min_bookings") ?? "").trim();
  const min = raw === "" ? null : Number(raw);
  if (min !== null && (!Number.isFinite(min) || min < 0)) {
    return { ok: false, message: "A minimum cannot be negative." };
  }

  const supabase = createClient();
  const { data, error } = await supabase.rpc("set_series_guarantee", {
    p_series_id: String(fd.get("id") ?? ""),
    p_tier: tier,
    p_min_bookings: min === null ? undefined : Math.floor(min),
    p_core_cutoff_hours: undefined,
  });
  if (error) return { ok: false, message: say(error.message) };

  refresh();
  const n = (data as unknown as { occurrences_updated?: number })?.occurrences_updated ?? 0;
  return {
    ok: true,
    message:
      (tier === "always"
        ? "Set to always. It runs whatever the numbers are and is never cancelled for them."
        : tier === "flex"
        ? "Set to flex. It runs only if it reaches its minimum by the cutoff."
        : "Set to core. It runs if it reaches its minimum, and pays a holding rate if it does not.")
      + (n ? ` ${n} class${n === 1 ? "" : "es"} already on the calendar updated.` : ""),
  };
}
