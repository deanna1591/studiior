import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";
import type { Insight } from "@/components/morning-brief";
import { formatMoney } from "@/lib/plans";

/**
 * Today's brief for the staff home.
 *
 * Reads only. Generation is a scheduled job — studios_due_for_brief() names
 * the studios whose local clock has reached morning_brief_send_at minus the
 * lead time, and something outside the database calls generate_morning_brief()
 * for each. Opening the dashboard must never be what makes the brief exist, or
 * a studio that does not log in never has one and the day it does log in it
 * gets a brief written at noon.
 */
export async function todaysBrief(
  supabase: SupabaseClient<Database>,
  studioId: string,
  timeZone: string,
) {
  const today = new Intl.DateTimeFormat("en-CA", { timeZone }).format(new Date());

  const { data: brief } = await supabase
    .from("morning_briefs")
    .select("id, brief_date, summary, metrics")
    .eq("studio_id", studioId)
    .eq("brief_date", today)
    .maybeSingle();
  if (!brief) return null;

  // Everything generated for today, so the screen can reconcile the summary
  // with the list. The summary is written once at generation and describes the
  // morning as it was; as items are actioned or dismissed the list shrinks and
  // the sentence would otherwise be describing a card that is no longer there.
  // Rewriting the stored summary as someone works would make the brief a live
  // dashboard rather than a record of the morning, so the count is what
  // reconciles them.
  const { count: handled } = await supabase
    .from("ai_insights")
    .select("id", { count: "exact", head: true })
    .eq("studio_id", studioId)
    .eq("for_date", today)
    .neq("status", "new");

  const { data: insights } = await supabase
    .from("ai_insights")
    .select("id, type, severity, title, observation, why_it_matters, recommended_action, action_type, action_payload, estimated_impact_cents")
    .eq("studio_id", studioId)
    .eq("for_date", today)
    .eq("status", "new")
    .order("severity")
    .order("estimated_impact_cents", { ascending: false, nullsFirst: false });

  const metrics = (brief.metrics ?? {}) as { currency?: string };
  const currency = metrics.currency ?? "GBP";
  const money: Record<string, string | null> = {};
  for (const i of insights ?? []) {
    money[i.id] = i.estimated_impact_cents
      ? formatMoney(i.estimated_impact_cents, currency)
      : null;
  }

  // Urgent first, then warnings — the same order the summary sentence uses.
  const rank: Record<string, number> = { urgent: 0, warning: 1, info: 2 };
  const ordered = [...(insights ?? [])].sort(
    (a, b) => (rank[a.severity] ?? 3) - (rank[b.severity] ?? 3),
  );

  return {
    handled: handled ?? 0,
    summary: brief.summary,
    insights: ordered as unknown as Insight[],
    money,
    dateLabel: new Intl.DateTimeFormat("en-GB", {
      timeZone, weekday: "long", day: "numeric", month: "long",
    }).format(new Date()),
  };
}
