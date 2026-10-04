import type { SupabaseClient } from "@supabase/supabase-js";
import type { StandingCoverage } from "./availability-line";

/**
 * Who has a STANDING weekly availability pattern covering the collected month —
 * read directly from `instructor_availability` under RLS (a manager may SELECT
 * it: policy `availability_manager_all` is `is_manager_up(studio_id)` FOR ALL),
 * which is why this needs no new function. Decision 46 follow-up.
 *
 * A standing-pattern row is `submission_id IS NULL` with a `day_of_week` and
 * `approval_status = 'approved'` — the shape the admin-side editor writes and
 * the shape the scheduler's step 4 reads. "Covers the month" is the ordinary
 * interval overlap against the collected month's [first, last]:
 *   (effective_from is null or <= last) and (effective_to is null or >= first).
 *
 * Per instructor: an open-ended row (effective_to null) means "no end date" and
 * wins; otherwise the latest effective_to among covering rows. Only instructors
 * WITH a covering pattern appear in the map — absent means none.
 */
export async function standingCoverage(
  supabase: SupabaseClient,
  studioId: string,
  periodStart: string,
  periodEnd: string,
): Promise<Map<string, StandingCoverage>> {
  const { data } = await supabase
    .from("instructor_availability")
    .select("instructor_id, effective_to")
    .eq("studio_id", studioId)
    .is("submission_id", null)
    .not("day_of_week", "is", null)
    .eq("approval_status", "approved")
    .eq("is_available", true)
    .or(`effective_from.is.null,effective_from.lte.${periodEnd}`)
    .or(`effective_to.is.null,effective_to.gte.${periodStart}`);

  const rows = (data ?? []) as { instructor_id: string; effective_to: string | null }[];
  const openEnded = new Set<string>();
  const latest = new Map<string, string>();
  for (const r of rows) {
    if (r.effective_to === null) {
      openEnded.add(r.instructor_id);
    } else {
      const have = latest.get(r.instructor_id);
      if (!have || r.effective_to > have) latest.set(r.instructor_id, r.effective_to);
    }
  }
  const out = new Map<string, StandingCoverage>();
  for (const id of new Set(rows.map((r) => r.instructor_id))) {
    // Open-ended wins: a pattern with no end date reads "no end date" even if
    // some of its day-rows carry an end.
    out.set(id, { endsOn: openEnded.has(id) ? null : (latest.get(id) ?? null) });
  }
  return out;
}
