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
  // Passed in rather than fetched. It arrived with the staff context, and
  // asking for it again here was a third request for an answer already held.
  billing?: { status: string | null; daysLeft: number },
): Promise<BannerMsg | null> {
  const [failed, pastDue] = await Promise.all([
    supabase.from("payments").select("id", { count: "exact", head: true })
      .eq("studio_id", studioId).eq("status", "failed"),
    supabase.from("memberships").select("id", { count: "exact", head: true })
      .eq("studio_id", studioId).eq("status", "past_due"),
  ]);

  const nFailed = failed.count ?? 0;
  const nPastDue = pastDue.count ?? 0;
  const bill = billing ?? null;

  return topBanner([
    // Above everything, including a member's failed card. Those cost the studio
    // one booking; this one stops every class running, and a studio must never
    // arrive at lockout surprised. It shows from day one of grace and counts
    // down, so "14 days" turning into "2 days" is itself the warning.
    bill?.status === "past_due"
      ? {
          kind: "payment_failed" as const,
          text: `Your Studiior subscription needs attention. ${
            bill.daysLeft === 0
              ? "The studio locks today"
              : `${bill.daysLeft} day${bill.daysLeft === 1 ? "" : "s"} left`
          } before staff and members are locked out.`,
          action: { href: "/billing", label: "Sort it out" },
        }
      : null,
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
