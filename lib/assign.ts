import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";
import { studioDateKey } from "@/lib/tz";

/**
 * Who could take an unstaffed class, in the cover board's order.
 *
 * The ONE definition of the assign candidate list, shared by the roster's
 * Assign panel and the calendar's Assign popover so the two cannot drift.
 * Three questions per instructor, the same the person deciding would get from
 * the scheduler:
 *   - valid_on (the DATE) is a HARD gate — move_occurrence() refuses outside it,
 *     so an instructor not working that week is not offered at all.
 *   - qualified and free only ORDER and LABEL: qualified-and-available first,
 *     the rest labelled ("not down to teach this", "outside the hours they gave
 *     us") rather than hidden — Decision 9, a human may override stated hours.
 */
export type AssignCandidate = {
  id: string;
  display_name: string;
  qualified: boolean;
  free: boolean;
};

export async function computeAssignCandidates(
  supabase: SupabaseClient<Database>,
  occ: { class_type_id: string | null; starts_at: string; ends_at: string },
  timeZone: string,
): Promise<AssignCandidate[]> {
  const day = studioDateKey(new Date(occ.starts_at), timeZone);
  const { data: instructors } = await supabase
    .from("instructors").select("id, display_name").eq("status", "active").order("display_name");

  const rows = await Promise.all((instructors ?? []).map(async (x) => {
    const [{ data: valid }, { data: qualified }, { data: free }] = await Promise.all([
      supabase.rpc("instructor_valid_on", { p_instructor_id: x.id, p_on: day }),
      occ.class_type_id
        ? supabase.rpc("instructor_qualified", { p_instructor_id: x.id, p_class_type_id: occ.class_type_id })
        : Promise.resolve({ data: false }),
      supabase.rpc("instructor_available_at", {
        p_instructor_id: x.id, p_starts_at: occ.starts_at, p_ends_at: occ.ends_at,
      }),
    ]);
    return { id: x.id, display_name: x.display_name,
             valid: valid !== false, qualified: qualified === true, free: free !== false };
  }));

  return rows
    .filter((r) => r.valid)
    .map(({ id, display_name, qualified, free }) => ({ id, display_name, qualified, free }))
    // Qualified-and-available first so the top of the list is the safe pick;
    // the component splits them into the primary group and "show all".
    .sort((a, b) => Number(b.qualified && b.free) - Number(a.qualified && a.free)
      || a.display_name.localeCompare(b.display_name));
}
