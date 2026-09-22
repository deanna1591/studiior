import { createClient } from "@/lib/supabase/server";

// Shared between the /series form actions and the Schedule calendar's
// click-to-create (Decision 37). Kept OUT of the "use server" actions file
// because a "use server" module may only export async server actions — these
// synchronous helpers and the single series-insert live here so both callers
// share one validation and one series creator, never a second.

export const text = (fd: FormData, k: string) => String(fd.get(k) ?? "").trim();
export const nullable = (fd: FormData, k: string) => text(fd, k) || null;
/**
 * A genuinely nullable RPC argument. `supabase gen types` models every argument
 * without a SQL default as non-nullable, even where the function takes null and
 * a series with no class type is ordinary. PostgREST sends JSON null fine; only
 * the generated type disagrees. Cast in one place with the reason attached.
 */
export const orNull = (fd: FormData, k: string) =>
  (text(fd, k) || null) as unknown as string;
export const num = (fd: FormData, k: string) => {
  const n = Number(text(fd, k));
  return Number.isFinite(n) ? Math.floor(n) : 0;
};

/**
 * PT422 is the one a studio will actually meet: the RRULE controls cannot
 * produce a rule the parser refuses, but a hand-made row, an import or a demo
 * studio can.
 */
export const say = (m: string) =>
  /PT403/.test(m) ? "Only owners and managers change the timetable."
  : /PT402/.test(m) ? "This studio's Studiior subscription is not active. Nothing has been deleted."
  : /PT404/.test(m) ? "That series no longer exists."
  : /PT422/.test(m) ? `This series has a repeat rule Studiior cannot keep: ${m.replace(/^.*?, /, "")}`
  : m;

export function fields(fd: FormData) {
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

export function invalid(f: ReturnType<typeof fields>): string | null {
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
 * The one series-creation mechanism, shared by /series/new and the calendar's
 * click-to-create (Decision 37). A plain INSERT: `series_manager_write` is the
 * boundary, 057's trigger materialises twelve months the moment the row lands,
 * and 061's trigger runs the assignment engine behind it — so there must not be
 * a SECOND series creator that could drift from this one. Returns the id, or the
 * refusal in words; the CALLER decides whether to redirect (the /series form) or
 * render the result in a modal (the calendar).
 */
export async function insertSeriesRow(
  studioId: string,
  f: ReturnType<typeof fields>,
): Promise<{ ok: true; id: string } | { ok: false; error: string }> {
  const supabase = createClient();
  const { data: loc } = await supabase.from("locations").select("id")
    .eq("studio_id", studioId).eq("is_primary", true).maybeSingle();
  if (!loc) return { ok: false, error: "This studio has no location to put a class in." };

  const { data, error } = await supabase.from("class_series").insert({
    studio_id: studioId, location_id: loc.id,
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
      ? { ok: false, error: "Your role cannot change the timetable. Owners and managers only." }
      : { ok: false, error: say(error.message) };
  }
  if (!data) return { ok: false, error: "Nothing was saved. Your role may not change the timetable." };
  return { ok: true, id: data.id };
}
