"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

export type SeriesState = { error: string } | null;

const text = (fd: FormData, k: string) => String(fd.get(k) ?? "").trim();
const nullable = (fd: FormData, k: string) => text(fd, k) || null;
/**
 * A genuinely nullable RPC argument.
 *
 * `supabase gen types` models every argument without a SQL default as
 * non-nullable, so `p_class_type_id: string` — even though the function takes
 * null and a series with no class type is ordinary. PostgREST sends JSON null
 * perfectly well; only the generated type disagrees. Cast in one place with the
 * reason attached rather than `as never` at four call sites.
 */
const orNull = (fd: FormData, k: string) =>
  (text(fd, k) || null) as unknown as string;
const num = (fd: FormData, k: string) => {
  const n = Number(text(fd, k));
  return Number.isFinite(n) ? Math.floor(n) : 0;
};

/**
 * PT422 is the one a studio will actually meet: the RRULE controls cannot
 * produce a rule the parser refuses, but a hand-made row, an import or a demo
 * studio can, and then editing it has to say something better than the raw
 * message.
 */
const say = (m: string) =>
  /PT403/.test(m) ? "Only owners and managers change the timetable."
  : /PT402/.test(m) ? "This studio's Studiior subscription is not active. Nothing has been deleted."
  : /PT404/.test(m) ? "That series no longer exists."
  : /PT422/.test(m) ? `This series has a repeat rule Studiior cannot keep: ${m.replace(/^.*?, /, "")}`
  : m;

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

function fields(fd: FormData) {
  return {
    p_name: text(fd, "name"),
    p_class_type_id: orNull(fd, "class_type_id"),
    p_room_id: orNull(fd, "room_id"),
    p_instructor_id: orNull(fd, "instructor_id"),
    p_capacity: num(fd, "capacity"),
    p_duration_minutes: num(fd, "duration_minutes"),
    p_rrule: text(fd, "rrule"),
    p_starts_on: text(fd, "starts_on"),
    p_ends_on: orNull(fd, "ends_on"),
    p_time_of_day: text(fd, "time_of_day"),
    p_description: orNull(fd, "description"),
  };
}

function invalid(f: ReturnType<typeof fields>): string | null {
  if (!f.p_name) return "This series needs a name.";
  if (!/BYDAY=[A-Z]/.test(f.p_rrule)) return "Pick at least one day of the week.";
  if (!f.p_starts_on) return "Pick the date the series starts.";
  if (!f.p_time_of_day) return "Pick a start time.";
  if (f.p_capacity < 1) return "Capacity must be at least 1.";
  if (f.p_duration_minutes < 1) return "A class has to last at least a minute.";
  if (f.p_ends_on && f.p_ends_on < f.p_starts_on) return "The end date is before the start date.";
  return null;
}

/**
 * Creating one.
 *
 * A plain insert: `series_manager_write` is the boundary, and 057's trigger
 * materialises twelve months the moment the row lands, with 061's trigger
 * running the assignment engine behind it. So the form's whole job here really
 * is to write the row correctly — which is only true for CREATE. Editing is
 * `update_series()`, because 057's trigger generates and never moves, and an
 * unguarded edit doubles the studio's timetable for a year.
 */
export async function createSeries(_prev: SeriesState, fd: FormData): Promise<SeriesState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };
  const f = fields(fd);
  const bad = invalid(f);
  if (bad) return { error: bad };

  const supabase = createClient();
  const { data: loc } = await supabase.from("locations").select("id")
    .eq("studio_id", ctx.studioId).eq("is_primary", true).maybeSingle();
  if (!loc) return { error: "This studio has no location to put a class in." };

  const { data, error } = await supabase.from("class_series").insert({
    studio_id: ctx.studioId, location_id: loc.id,
    name: f.p_name, class_type_id: f.p_class_type_id, room_id: f.p_room_id,
    instructor_id: f.p_instructor_id, capacity: f.p_capacity,
    duration_minutes: f.p_duration_minutes, rrule: f.p_rrule,
    starts_on: f.p_starts_on, ends_on: f.p_ends_on,
    time_of_day: f.p_time_of_day, description: f.p_description,
  }).select("id").maybeSingle();

  // A refused INSERT errors; a refused UPDATE returns nothing. Both are checked
  // because "saved" with no row written is the worst thing this screen can say.
  if (error) {
    return /row-level security/i.test(error.message) || error.code === "42501"
      ? { error: "Your role cannot change the timetable. Owners and managers only." }
      : { error: say(error.message) };
  }
  if (!data) return { error: "Nothing was saved. Your role may not change the timetable." };

  revalidatePath("/series"); revalidatePath("/schedule"); revalidatePath("/");
  redirect(`/series/${data.id}`);
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
