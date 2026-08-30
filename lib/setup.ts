import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";

export type SetupState = Record<string, { done: boolean; dismissed: boolean }>;

/**
 * The checklist, and whether it is finished.
 *
 * studio_setup_state derives every tick from live data rather than a stored
 * flag, so deleting the last room brings that item back. Dismissed items are
 * out of the count entirely — a studio that will never use Stripe should be
 * able to reach the end of the list.
 */
export async function setupSummary(
  supabase: SupabaseClient<Database>,
  studioId: string,
): Promise<{ state: SetupState; done: number; total: number; complete: boolean }> {
  const { data } = await supabase.rpc("studio_setup_state", { p_studio_id: studioId });
  const state = (data ?? {}) as unknown as SetupState;
  const live = Object.values(state).filter((v) => !v.dismissed);
  const done = live.filter((v) => v.done).length;
  return { state, done, total: live.length, complete: live.length > 0 && done === live.length };
}
