import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { todaysBrief } from "@/lib/brief";
import { dashboardData, narrativeFor, revenueWindow, studioToday } from "@/lib/dashboard";
import { searchStudio } from "@/app/staff/search-actions";
import MorningBrief from "@/components/morning-brief";
import InsightsPanel from "@/components/dashboard/insights-panel";
import TopBar from "@/components/dashboard/topbar";
import KpiCards from "@/components/dashboard/kpi-cards";
import RevenueWidget from "@/components/dashboard/revenue-widget";
import Heatmap from "@/components/dashboard/heatmap";
import HealthWidget from "@/components/dashboard/health-widget";
import ActivityFeed from "@/components/dashboard/activity-feed";
import Tasks from "@/components/dashboard/tasks";
import MonthSnapshot from "@/components/dashboard/month-snapshot";
import { Block, BlockEmpty } from "@/components/dashboard/block";
import { AppShell, Empty, Rows } from "@/components/ui";
import { ScheduleRow, type Occ } from "@/components/schedule-rows";
import { addDays, dayStart, relativeDayName, fmtDayLong } from "@/lib/time";

export const dynamic = "force-dynamic";

/**
 * Bible Ch. 4 — the dashboard, against the five questions an owner should be
 * able to answer in thirty seconds:
 *
 *   How is my studio doing today?  → the KPI row and the revenue block
 *   What needs my attention?       → the brief, then "Needs you"
 *   Who needs my attention?        → member health, and the insights that name
 *                                    people
 *   What am I missing?             → when the week fills
 *   What should I do next?         → every one of the above ends in a link to
 *                                    the screen where the thing gets done
 *
 * EVERY FIGURE COMES FROM MIGRATION 091. Nothing here computes one — a
 * percentage worked out in TypeScript is a second definition of a number the
 * database already has, and the two would agree exactly once.
 *
 * Manager-up for everything but today's classes. Permissions §12 note 21 keeps
 * revenue and churn away from instructors and front desk, and it is the
 * policies and the guards inside migration 091's functions that enforce it —
 * this only decides what to ask for.
 */
export default async function Dashboard({
  searchParams,
}: {
  searchParams: { rev?: string; month?: string };
}) {
  const screen = await staffScreen("/");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  const manager = isManagerUp(ctx.role);
  const today = studioToday(ctx.timeZone);
  const days = revenueWindow(searchParams.rev);

  // Two hops for the whole screen. staffScreen() is the first; everything
  // below is one batch that waits on nothing else in it.
  const [brief, data, todays] = await Promise.all([
    manager ? todaysBrief(supabase, ctx.studioId, ctx.timeZone) : Promise.resolve(null),
    manager
      ? dashboardData(supabase, ctx.studioId, ctx.timeZone, {
          revenueDays: days,
          // Only a real date reaches the database; anything else falls back to
          // the current month rather than raising on a cast.
          month: /^\d{4}-\d{2}-\d{2}$/.test(searchParams.month ?? "")
            ? searchParams.month : null,
        })
      : Promise.resolve(null),
    // The STUDIO's day, not the server's. A Manila studio's today is a
    // different date from the server's for most of the world's hours, and a
    // 07:00 Manila class is stored at 23:00 UTC the day before.
    supabase
      .from("class_occurrences")
      .select("id, name, starts_at, capacity, booked_count, waitlist_count, status, room_id, instructor_id, instructors!instructor_id(display_name), rooms(name)")
      .gte("starts_at", dayStart(new Date(), ctx.timeZone).toISOString())
      .lt("starts_at", addDays(dayStart(new Date(), ctx.timeZone), 1).toISOString())
      .order("starts_at"),
  ]);

  const dayLabel = relativeDayName(`${today}T12:00:00Z`, ctx.timeZone)
    ?? fmtDayLong(`${today}T12:00:00Z`, ctx.timeZone);

  const keepMonth = searchParams.month ? `&month=${searchParams.month}` : "";
  const revHref = (d: number) =>
    d === 30 && !keepMonth ? "/" : `/?rev=${d}${keepMonth}`;

  // Quick Add offers only what THIS role may actually do. The Bible's list is
  // nine items; four of them (challenge, workshop, promotion, announcement)
  // have no screen in this product and are absent rather than offered, and the
  // rest are filtered by Permissions — front desk creates members (§5) and
  // nothing else, and an instructor creates nothing at all, so they get no
  // button rather than a menu of refusals. Every entry here is a destination
  // the caller will be let into.
  const quickAdd = manager
    ? [
        { label: "Member", href: "/members/new", sub: "The walk-in at the counter" },
        { label: "Class", href: "/schedule", sub: "Click an empty slot on the day view" },
        { label: "Recurring class", href: "/series/new", sub: "A weekly slot that fills itself" },
        { label: "Instructor", href: "/instructors/new", sub: "A teaching record, with or without a login" },
        { label: "Plan", href: "/plans/new", sub: "Membership, pack or drop-in" },
        { label: "Room", href: "/rooms/new", sub: "Somewhere for a class to happen" },
        { label: "Import members", href: "/imports/new", sub: "From a CSV, with an undo" },
      ]
    : ctx.role === "front_desk"
      ? [{ label: "Member", href: "/members/new", sub: "The walk-in at the counter" }]
      : [];

  return (
    <AppShell {...shell} title="Dashboard">
      <TopBar quickAdd={quickAdd} search={searchStudio} />

      {/* 4.2 — the narrative first. An owner who reads one sentence and closes
          the tab should still know what today looks like.
          Generation is a cron job: opening this page must never be what makes
          the brief exist, or a studio that does not log in never gets one and
          the day it does log in it gets a brief written at noon. So a missing
          brief is a real state and says so, rather than leaving a gap where
          the most-read thing on the screen should be. */}
      {manager && (brief ? (
        <MorningBrief
          summary={brief.summary}
          insights={[]}
          money={brief.money}
          dateLabel={brief.dateLabel}
          handled={brief.handled}
        />
      ) : (
        <section className="mb-8 border-y border-line bg-surface px-3 py-3">
          <h2 className="section-label text-ink-2">This morning</h2>
          <p className="mt-1.5 max-w-[60ch] text-[13px] leading-[19px] text-ink-2">
            Today&rsquo;s brief has not been written yet — it is composed for you
            each morning, before you open this. Your figures below are live
            either way.
          </p>
        </section>
      ))}

      {manager && data && (
        <>
          {/* 4.3 */}
          <div className="mb-8">
            <KpiCards
              cards={data.kpis?.cards ?? []}
              absent={data.absent}
              error={data.kpisError}
            />
          </div>

          {/* 4.4 and 4.5 */}
          <div className="mb-6 grid grid-cols-1 gap-4 xl:grid-cols-2">
            <RevenueWidget
              r={data.revenue}
              days={days}
              narrative={narrativeFor(data.narratives.revenue, days)}
              error={data.revenueError}
              hrefFor={revHref}
            />
            <Heatmap
              h={data.heatmap}
              narrative={narrativeFor(data.narratives.attendance, 90)}
              error={data.heatmapError}
            />
          </div>

          {/* 4.6 and 4.7 */}
          <div className="mb-6 grid grid-cols-1 gap-4 xl:grid-cols-2">
            {/* The roster row is built for the full content width and is 28px
                over inside a half-width column. Scrolls inside its own
                container rather than pushing the page sideways — the same rule
                the schedule grid follows. */}
            <Block
              title="Today's classes"
              hint={dayLabel}
              right={
                <Link href="/schedule" className="text-[12px] leading-4 text-lime-text underline underline-offset-4 hover:text-lime-text2">
                  Schedule
                </Link>
              }
              error={todays.error?.message ?? null}
            >
              {(todays.data ?? []).length === 0 ? (
                <BlockEmpty cta={{ href: "/series", label: "Set up your timetable" }}>
                  Nothing is on today. Every class you run shows up here with how
                  full it is and who is teaching it, so the morning is one glance.
                </BlockEmpty>
              ) : (
                <div className="-mx-1 overflow-x-auto px-1">
                  <div className="min-w-[560px]">
                    <Rows>
                      {(todays.data as Occ[]).map((o) => (
                        <ScheduleRow key={o.id} o={o} timeZone={ctx.timeZone} now={Date.now()} />
                      ))}
                    </Rows>
                  </div>
                </div>
              )}
            </Block>

            <InsightsPanel
              insights={brief?.insights ?? []}
              money={brief?.money ?? {}}
              handled={brief?.handled ?? 0}
              lead={data.narratives.lead ?? null}
            />
          </div>

          {/* 4.8 and 4.9 */}
          <div className="mb-6 grid grid-cols-1 gap-4 xl:grid-cols-2">
            <HealthWidget h={data.health} error={data.healthError} />
            <ActivityFeed a={data.activity} timeZone={ctx.timeZone} error={data.activityError} />
          </div>

          {/* 4.11 and 4.10 */}
          <div className="grid grid-cols-1 gap-4 xl:grid-cols-2">
            <Tasks t={data.tasks} error={data.tasksError} />
            <MonthSnapshot m={data.month} weekStartsOn={data.month?.week_starts_on ?? 1} error={data.monthError} />
          </div>
        </>
      )}

      {/* Instructors and front desk: today's classes, and nothing that
          Permissions §12 keeps from them. Not a wall of refusals. */}
      {!manager && (
        <section>
          <h2 className="section-label mb-2 text-ink-2">{dayLabel}</h2>
          {(todays.data ?? []).length === 0 ? (
            <Empty>No classes today.</Empty>
          ) : (
            <Rows>
              {(todays.data as Occ[]).map((o) => (
                <ScheduleRow key={o.id} o={o} timeZone={ctx.timeZone} now={Date.now()} />
              ))}
            </Rows>
          )}
        </section>
      )}
    </AppShell>
  );
}
