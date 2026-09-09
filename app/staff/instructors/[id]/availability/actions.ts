"use server";

import { revalidatePath } from "next/cache";
import { getStaffContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export type AvailState = { ok: boolean; message: string } | null;

const refresh = (id: string) => {
  revalidatePath(`/instructors/${id}/availability`);
  revalidatePath("/schedule");
  revalidatePath("/shifts");
};

const say = (error: { message: string }) =>
  /PT403/.test(error.message)
    ? "Only the studio or the instructor themselves can set this."
  : /PT404/.test(error.message) ? "That instructor no longer exists."
  : /PT422/.test(error.message)
    ? error.message.replace(/^.*?:\s*/, "")
  : error.message;

/**
 * The whole week, in one call.
 *
 * The form posts every day it is showing, so what reaches the database is
 * always a complete pattern — including the days with no ranges, which is how
 * "Unavailable" is stated rather than merely implied by an absent row.
 * Copy-a-day-to-other-days happens in the browser, on the form state, so it
 * arrives here as an ordinary week and needs no special path.
 */
export async function saveAvailability(_prev: AvailState, fd: FormData): Promise<AvailState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const id = String(fd.get("instructor_id") ?? "");

  let days: unknown;
  try {
    days = JSON.parse(String(fd.get("days") ?? "[]"));
  } catch {
    return { ok: false, message: "That week did not come through. Try again." };
  }

  const supabase = createClient();
  const { data, error } = await supabase.rpc("set_instructor_availability", {
    p_instructor_id: id,
    p_days: days as never,
    p_effective_from: String(fd.get("effective_from") ?? "") || undefined,
    p_effective_to: String(fd.get("effective_to") ?? "") || undefined,
  });
  if (error) return { ok: false, message: say(error) };

  refresh(id);
  const n = Number(data ?? 0);
  return {
    ok: true,
    message: n === 0
      ? "Saved. They are down as unavailable every day."
      : `Saved — ${n} time range${n === 1 ? "" : "s"} across the week.`,
  };
}

export async function addException(_prev: AvailState, fd: FormData): Promise<AvailState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const id = String(fd.get("instructor_id") ?? "");
  const date = String(fd.get("date") ?? "");
  if (!date) return { ok: false, message: "Pick a date first." };

  const from = String(fd.get("from") ?? "").trim();
  const to = String(fd.get("to") ?? "").trim();
  // No times means the whole day is off. That is the common case by a long way:
  // "Sep 16 — unavailable" is what a planned absence looks like.
  const ranges = from && to ? [{ from, to }] : [];

  const supabase = createClient();
  const { error } = await supabase.rpc("set_availability_exception", {
    p_instructor_id: id,
    p_date: date,
    p_ranges: ranges as never,
    p_note: String(fd.get("note") ?? "").trim() || undefined,
  });
  if (error) return { ok: false, message: say(error) };

  refresh(id);
  return {
    ok: true,
    message: ranges.length
      ? "Saved. That date now overrides the weekly pattern."
      : "Saved. They are down as away that day.",
  };
}

export async function removeException(_prev: AvailState, fd: FormData): Promise<AvailState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const id = String(fd.get("instructor_id") ?? "");
  const supabase = createClient();
  const { error } = await supabase.rpc("clear_availability_exception", {
    p_instructor_id: id, p_date: String(fd.get("date") ?? ""),
  });
  if (error) return { ok: false, message: say(error) };
  refresh(id);
  return { ok: true, message: "Removed. The weekly pattern applies again." };
}

/**
 * The commitment. Manager-up only, and the database says so as well — an
 * instructor can read their own and cannot write it, because a minimum you can
 * lower yourself is not a minimum.
 */
export async function saveCommitment(_prev: AvailState, fd: FormData): Promise<AvailState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const id = String(fd.get("instructor_id") ?? "");
  const existing = String(fd.get("commitment_id") ?? "");

  const row = {
    studio_id: ctx.studioId,
    instructor_id: id,
    starts_on: String(fd.get("starts_on") ?? ""),
    ends_on: String(fd.get("ends_on") ?? "") || null,
    min_per_week: Number(fd.get("min_per_week") ?? 0),
    target_per_week: Number(fd.get("target_per_week") ?? 0),
    shift_preference: String(fd.get("shift_preference") ?? "both"),
  };
  if (!row.starts_on) return { ok: false, message: "A commitment needs a start date." };
  if (row.target_per_week && row.target_per_week < row.min_per_week) {
    return { ok: false, message: "The target cannot be below the minimum." };
  }

  const supabase = createClient();
  // A refused write does not raise — RLS makes the row invisible and PostgREST
  // answers 200 with an empty array. Both branches check what came back.
  const { data, error } = existing
    ? await supabase.from("instructor_commitments").update(row).eq("id", existing).select("id")
    : await supabase.from("instructor_commitments").insert(row).select("id");

  if (error) {
    return {
      ok: false,
      message: /instructor_commitments_one_live/.test(error.message)
        ? "They already have a live commitment. End that one first."
        : /check/.test(error.message)
          ? "Those dates or numbers do not make sense together."
          : error.message,
    };
  }
  if (!data || data.length === 0) {
    return { ok: false, message: "That was not saved — only owners and managers can set a commitment." };
  }

  refresh(id);
  return { ok: true, message: "Commitment saved. The weekly pattern will default to these dates." };
}

export async function endCommitment(_prev: AvailState, fd: FormData): Promise<AvailState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const supabase = createClient();
  const { data, error } = await supabase.from("instructor_commitments")
    .update({ status: "ended" })
    .eq("id", String(fd.get("commitment_id") ?? ""))
    .select("id");
  if (error) return { ok: false, message: error.message };
  if (!data || data.length === 0) {
    return { ok: false, message: "That was not changed — only owners and managers can end a commitment." };
  }
  refresh(String(fd.get("instructor_id") ?? ""));
  return { ok: true, message: "Ended. Their availability pattern stays as it is." };
}
