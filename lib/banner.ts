import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";
import { topBanner, type BannerMsg } from "@/components/banner";

/**
 * Gather every condition that could claim the banner slot, then let priority
 * decide. Counted rather than listed: the banner says how many and where to
 * look, and the screen it links to does the explaining.
 */
export async function studioBanner(
  supabase: SupabaseClient<Database>,
  studioId: string,
  setupComplete: boolean,
): Promise<BannerMsg | null> {
  const [failed, pastDue] = await Promise.all([
    supabase.from("payments").select("id", { count: "exact", head: true })
      .eq("studio_id", studioId).eq("status", "failed"),
    supabase.from("memberships").select("id", { count: "exact", head: true })
      .eq("studio_id", studioId).eq("status", "past_due"),
  ]);

  const nFailed = failed.count ?? 0;
  const nPastDue = pastDue.count ?? 0;

  return topBanner([
    nFailed > 0
      ? {
          kind: "payment_failed",
          text: `${nFailed} payment${nFailed === 1 ? "" : "s"} failed and ${
            nFailed === 1 ? "has" : "have"} not been retried.`,
          action: { href: "/members?filter=payment", label: "See who" },
        }
      : null,
    nPastDue > 0
      ? {
          kind: "past_due",
          text: `${nPastDue} membership${nPastDue === 1 ? " is" : "s are"} past due, so ${
            nPastDue === 1 ? "that member cannot" : "those members cannot"} book.`,
          action: { href: "/members?filter=past_due", label: "See who" },
        }
      : null,
    !setupComplete
      ? {
          kind: "setup",
          text: "Your studio is not finished being set up.",
          action: { href: "/setup", label: "Pick up where you left off" },
        }
      : null,
  ]);
}
