import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";

export type SetupState = Record<string, { done: boolean; dismissed: boolean; optional?: boolean }>;

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
  // Optional items (Decision 16: connect_stripe) are excluded from the count.
  // A studio that takes cash has finished setting up, and counting an item it
  // will never do would leave the banner and the progress figure stuck at
  // "6 of 7" forever.
  const live = Object.values(state).filter((v) => !v.dismissed && !v.optional);
  const done = live.filter((v) => v.done).length;
  return { state, done, total: live.length, complete: live.length > 0 && done === live.length };
}
