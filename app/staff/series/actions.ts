"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";
import { text, nullable, fields, invalid, insertSeriesRow, say, seriesSkipWarning } from "./shared";

export type SeriesState = { error: string } | null;

/** What update_series() answers with, in the shapes the screen has to render. */
export type EditResult =
  | { ok: true; effective_from: string; moved: number; cancelled: number;
      restored: number; added: number; unchanged: number; left_as_edited: number;
      members_emailed: number; conflicts: Conflict[];
      // What the preview PREDICTED, beside what the apply actually did. They
      // used to be the same number: update_series() returned the preview's
      // counters whatever the apply managed, so an edit that moved nothing
      // still reported "19 moved" and the studio was told it had worked.
      predicted: { moved: number; cancelled: number; restored: number };
      // Asked of the calendar afterwards, not of any counter. Non-zero means
      // the classes are not where the series says they should be.
      still_out_of_step: number }
  | { ok: false; requires_confirmation: true; effective_from: string;
      will_move: number; will_cancel: number; will_restore: number; will_add: number;
      unchanged: number; left_as_edited: number; members_emailed: number; horizon_to: string }
  | { ok: false; reason: "members_booked_on_dropped_classes"; effective_from: string;
      blocked: { occurrence_id: string; local: string; booked: number }[] }
  | { ok: false; reason: "capacity_below_booked"; capacity: number; effective_from: string;
      over_capacity: { occurrence_id: string; local: string; booked: number }[] };

export type Conflict = {
  occurrence_id: string; local: string; reason: string;
};

export type EditState = { error: string } | { result: EditResult } | null;

/**
 * Creating one. A plain insert through the shared `insertSeriesRow`:
 * `series_manager_write` is the boundary, 057's trigger materialises twelve
 * months the moment the row lands, and 061's trigger assigns behind it. Editing
 * is `update_series()`, because 057's trigger generates and never moves, and an
 * unguarded edit doubles the studio's timetable for a year.
 */
export async function createSeries(_prev: SeriesState, fd: FormData): Promise<SeriesState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };
  const f = fields(fd);
  const bad = invalid(f);
  if (bad) return { error: bad };

  const res = await insertSeriesRow(ctx.studioId, f);
  if (!res.ok) return { error: res.error };

  // Decision 37 follow-up: the generator silently skips a week where the
  // instructor or room is busy. Carry the shortfall to the series screen, which
  // banners it (the same warning the calendar modal shows).
  const skip = await seriesSkipWarning(ctx.studioId, ctx.timeZone, res.id, f);

  revalidatePath("/series"); revalidatePath("/schedule"); revalidatePath("/");
  redirect(skip
    ? `/series/${res.id}?expected=${skip.expected}&made=${skip.created}`
    : `/series/${res.id}`);
}

async function edit(fd: FormData, confirm: boolean): Promise<EditState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };
  const id = text(fd, "id");
  if (!id) return { error: "No series to change." };
  const f = fields(fd);
  const bad = invalid(f);
  if (bad) return { error: bad };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("update_series", {
    p_series_id: id, ...f,
    // Defaulted in SQL to "tomorrow in studio time", so omitting is meaningful.
    p_effective_from: nullable(fd, "effective_from") ?? undefined,
    p_confirm: confirm,
  });
  if (error) return { error: say(error.message) };

  if (confirm) {
    revalidatePath("/series"); revalidatePath(`/series/${id}`);
    revalidatePath("/schedule"); revalidatePath("/");
  }
  return { result: data as unknown as EditResult };
}

/** Says what it would do and writes nothing. */
export async function previewSeries(_prev: EditState, fd: FormData) {
  return edit(fd, false);
}

/**
 * The second, deliberate press.
 *
 * It re-runs rather than replaying the preview, for the same reason the fill
 * screen does: between the two presses somebody may have booked a class the
 * preview said was empty, and cancelling it then would be exactly the silent
 * loss of somebody's spot the refusal exists to prevent. The counts shown
 * afterwards are what actually happened.
 */
export async function applySeries(_prev: EditState, fd: FormData) {
  return edit(fd, true);
}
