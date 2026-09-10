import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";

/**
 * Everything Chapter 4's dashboard needs, in ONE parallel batch.
 *
 * Serial depth is the cost, not the number of queries — the member Home was
 * once 14 requests 7 deep and 1.75s of pure latency from Manila. Nothing here
 * depends on anything else here, so nothing waits: with staffScreen() that is
 * two hops for the whole screen, which is the pattern the rest of the app
 * follows.
 *
 * Every figure comes from migration 091. Nothing on this side computes one —
 * a percentage worked out in TypeScript is a second definition of a number the
 * database already has, and the two would agree exactly once.
 */

export type Trend = {
  direction: "up" | "down" | "flat";
  delta: number;
  pct: number | null;
  prior: number | null;
  basis: string;
};

export type Kpi = {
  key: string;
  label: string;
  sub?: string | null;
  state: "ok" | "empty";
  kind: "money" | "count" | "percent";
  value: number | null;
  currency?: string;
  trend?: Trend | null;
  tone?: "normal" | "amber";
  href: string;
  forecast?: boolean;
  empty_hint?: string;
};

export type Narrative = {
  state: "ok" | "none" | "nothing_to_say";
  text: string | null;
  source: "ai" | "written" | null;
  /** The window the sentence describes, in days. Null where it has none. */
  covers_days?: number | null;
  reason?: string;
  lead_insight_id?: string | null;
};

/**
 * A written sentence, only where it is about the window on screen.
 *
 * A revenue narrative is generated about 30 days. Rendered over a 90-day chart
 * it becomes a caption for a figure it has never seen — the same disagreement
 * between prose and number that the verifier refuses inside the database,
 * arriving instead at the screen. So the window travels with the sentence and
 * this is the one place that compares them.
 */
export function narrativeFor(n: Narrative | null | undefined, showingDays: number): string | null {
  if (!n || n.state !== "ok" || !n.text) return null;
  if (n.covers_days != null && n.covers_days !== showingDays) return null;
  return n.text;
}

export type DashboardData = Awaited<ReturnType<typeof dashboardData>>;

const REVENUE_WINDOWS = [7, 30, 90, 365] as const;
export type RevenueWindow = (typeof REVENUE_WINDOWS)[number];

export function revenueWindow(v: string | undefined): RevenueWindow {
  const n = Number(v);
  return (REVENUE_WINDOWS as readonly number[]).includes(n) ? (n as RevenueWindow) : 30;
}

/**
 * Money as a whole unit, for the dashboard only.
 *
 * TWO REASONS, and the second is the one that matters. "CZK 113,100.00" is
 * 244px of mono in a 221px card and overflowed it — but it also disagreed in
 * FORM with the written sentence beside it, which says "113,100 CZK" because
 * dashboard_money_text() rounds to the unit. A figure and a sentence about the
 * same figure rendering differently is small, and it is exactly the kind of
 * small that makes an owner stop trusting both.
 *
 * The cost, stated: a total of 39,650.47 shows as 39,650, and the parts of a
 * breakdown can round to one unit off their total. Exact amounts live on the
 * payment record, which is where somebody reconciling a till is looking.
 */
export function money(cents: number, currency: string): string {
  try {
    return new Intl.NumberFormat("en-GB", {
      style: "currency", currency,
      minimumFractionDigits: 0, maximumFractionDigits: 0,
    }).format(cents / 100);
  } catch {
    return `${Math.round(cents / 100)} ${currency}`;
  }
}

/**
 * The studio's own date, computed rather than fetched.
 *
 * studio_today() still exists for callers already inside the database, but a
 * page holding a timezone should not pay a round trip to learn what day it is
 * — Intl carries the same IANA rules Postgres does, checked against hosted.
 */
export function studioToday(timeZone: string, offsetDays = 0): string {
  const d = new Date();
  if (offsetDays) d.setUTCDate(d.getUTCDate() + offsetDays);
  return new Intl.DateTimeFormat("en-CA", { timeZone }).format(d);
}

export async function dashboardData(
  supabase: SupabaseClient<Database>,
  studioId: string,
  timeZone: string,
  opts: { revenueDays?: number; month?: string | null } = {},
) {
  const days = opts.revenueDays ?? 30;
  const today = studioToday(timeZone);
  const from = studioToday(timeZone, -(days - 1));

  const [
    kpis, revenue, heatmap, health, activity, tasks, month, absent,
    nRevenue, nAttendance, nLead,
  ] = await Promise.all([
    supabase.rpc("dashboard_kpis", { p_studio_id: studioId }),
    supabase.rpc("dashboard_revenue", { p_studio_id: studioId, p_from: from, p_to: today }),
    supabase.rpc("dashboard_heatmap", { p_studio_id: studioId, p_days: 90 }),
    supabase.rpc("dashboard_health", { p_studio_id: studioId }),
    supabase.rpc("dashboard_activity", { p_studio_id: studioId, p_limit: 12 }),
    supabase.rpc("dashboard_tasks", { p_studio_id: studioId }),
    supabase.rpc("dashboard_month", { p_studio_id: studioId, p_month: opts.month ?? undefined }),
    supabase.rpc("dashboard_absent_cards", { p_studio_id: studioId }),
    supabase.rpc("dashboard_narrative", { p_studio_id: studioId, p_kind: "revenue" }),
    supabase.rpc("dashboard_narrative", { p_studio_id: studioId, p_kind: "attendance" }),
    supabase.rpc("dashboard_narrative", { p_studio_id: studioId, p_kind: "lead" }),
  ]);

  // A FAILED QUERY MUST NOT LOOK LIKE AN EMPTY STUDIO. schedule_range() raised
  // on every call in production for a week and was indistinguishable from a
  // studio with nothing on, so the blankness became the bug report while the
  // error sat unread in the response. Every block here carries its own error
  // and the screen renders it, in words, with the database's own message.
  const err = (r: { error: { message: string } | null }) => r.error?.message ?? null;

  return {
    today,
    days,
    kpis: (kpis.data ?? null) as { cards: Kpi[]; currency: string;
      forecast_months_needed: number; forecast_months_have: number } | null,
    kpisError: err(kpis),
    revenue: revenue.data as RevenueBlock | null,
    revenueError: err(revenue),
    heatmap: heatmap.data as HeatmapBlock | null,
    heatmapError: err(heatmap),
    health: health.data as HealthBlock | null,
    healthError: err(health),
    activity: activity.data as ActivityBlock | null,
    activityError: err(activity),
    tasks: tasks.data as TasksBlock | null,
    tasksError: err(tasks),
    month: month.data as MonthBlock | null,
    monthError: err(month),
    absent: (absent.data ?? []) as AbsentCard[],
    narratives: {
      revenue: nRevenue.data as Narrative | null,
      attendance: nAttendance.data as Narrative | null,
      lead: nLead.data as Narrative | null,
    },
  };
}

export type RevenueBlock = {
  from: string; to: string; days: number; currency: string;
  state: "ok" | "empty";
  total_cents: number;
  trend: Trend;
  series: { date: string; cents: number }[];
  by_source: { source: string; label: string; cents: number; pct: number }[];
  counts: { bookings: number; memberships_sold: number; refunds_cents: number };
  empty_hint: string;
};

export type HeatmapBlock = {
  days: number; timezone: string; state: "ok" | "empty";
  cells: { dow: number; hour: number; classes: number; booked: number;
           capacity: number; occupancy: number | null }[];
  peak: { dow: number; hour: number; classes: number; occupancy: number } | null;
  quiet: { dow: number; hour: number; classes: number; occupancy: number } | null;
  min_classes_for_pattern: number;
  empty_hint: string;
};

export type HealthBlock = {
  state: "ok" | "empty" | "not_computed";
  bands: { band: string; count: number; href: string }[];
  total: number; banded: number; not_computed: number;
  computed_at: string | null;
  empty_hint: string; not_computed_hint: string;
};

export type ActivityBlock = {
  state: "ok" | "empty";
  items: { id: string; type: string; title: string; description: string | null;
           occurred_at: string; member_id: string; member_name: string; href: string }[];
  empty_hint: string;
};

export type TasksBlock = {
  state: "ok" | "clear";
  tasks: { key: string; urgency: "urgent" | "soon" | "whenever"; count: number;
           title: string; detail: string; href: string; action: string }[];
  clear_hint: string; not_built: string;
};

export type MonthBlock = {
  month: string; today: string; timezone: string; state: "ok" | "empty";
  days: { date: string; classes: number; booked: number; capacity: number;
          closed: boolean; closure_reason: string | null; is_today: boolean }[];
  week_starts_on: number;
  total_classes: number; empty_hint: string;
};

export type AbsentCard = { key: string; label: string; why: string };
