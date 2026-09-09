import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";
import { topBanner, type BannerMsg } from "@/components/banner";
import { isManagerUp, type StaffRole } from "@/lib/auth";

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
  // Only owners and managers can answer a cover request, so only they get a
  // banner telling them to. An instructor was being shown "Answer it" pointing
  // at a screen the database refuses them — a banner nobody can act on is the
  // "insight without a working button" mistake wearing a different hat.
  role?: StaffRole,
): Promise<BannerMsg | null> {
  const canAnswerCover = role ? isManagerUp(role) : true;
  const [failed, pastDue, cover] = await Promise.all([
    supabase.from("payments").select("id", { count: "exact", head: true })
      .eq("studio_id", studioId).eq("status", "failed"),
    supabase.from("memberships").select("id", { count: "exact", head: true })
      .eq("studio_id", studioId).eq("status", "past_due"),
    // Decision 18. The times come back so the banner can say how close the
    // soonest one is — "in 2 hours" is the whole message, and a count alone
    // makes an emergency look like a queue.
    role && !isManagerUp(role)
      ? Promise.resolve({ data: [] as { class_occurrences: { starts_at: string } }[] })
      : supabase.from("cover_requests")
      .select("id, class_occurrences!inner(starts_at)")
      .eq("studio_id", studioId).eq("status", "pending")
      .eq("class_occurrences.status", "scheduled")
      .gt("class_occurrences.starts_at", new Date().toISOString())
      .order("starts_at", { referencedTable: "class_occurrences", ascending: true })
      .limit(20),
  ]);

  const nFailed = failed.count ?? 0;
  const nPastDue = pastDue.count ?? 0;
  const bill = billing ?? null;

  const covers = cover.data ?? [];
  const soonest = covers
    .map((c) => new Date(c.class_occurrences.starts_at).getTime())
    .sort((a, b) => a - b)[0];
  const hoursOut = soonest ? (soonest - Date.now()) / 3600e3 : null;

  return topBanner([
    // ABOVE THE SUBSCRIPTION WARNING, which is the only thing that has ever
    // outranked money here. Decision 18: staff approval is required, so a
    // request nobody has seen is a class nobody teaches — and unlike lockout,
    // which counts down over fourteen days, this one is measured in hours.
    covers.length > 0 && canAnswerCover
      ? {
          kind: "payment_failed" as const,
          text:
            hoursOut !== null && hoursOut <= 4
              ? `A class starting in ${
                  hoursOut < 1
                    ? `${Math.max(0, Math.round(hoursOut * 60))} minutes`
                    : `${Math.round(hoursOut)} hour${Math.round(hoursOut) === 1 ? "" : "s"}`
                } has an unanswered cover request. Nobody has released the instructor — they are still expected to teach it.`
              : `${covers.length} cover request${covers.length === 1 ? "" : "s"} ${
                  covers.length === 1 ? "is" : "are"} waiting on an answer.`,
          action: { href: "/shifts/cover", label: "Answer it" },
        }
      : null,
    // Above everything else, including a member's failed card. Those cost the studio
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
