import type { SupabaseClient } from "@supabase/supabase-js";
import type { PlanPrice } from "@/lib/promo";
import type { Database } from "@/lib/database.types";

/**
 * Decision 117 — every live plan of the studio priced now, in ONE call
 * (plan_prices_now). Keyed by plan id. A failed read returns an empty map, so a
 * screen falls back to the list price rather than breaking.
 */
export async function planPrices(supabase: SupabaseClient<Database>, studioId: string): Promise<Map<string, PlanPrice>> {
  const { data } = await supabase.rpc("plan_prices_now", { p_studio_id: studioId });
  const rows = (Array.isArray(data) ? data : []) as PlanPrice[];
  return new Map(rows.filter(Boolean).map((r) => [r.plan_id, r]));
}
