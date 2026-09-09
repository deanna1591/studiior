import Link from "next/link";
import { AppShell, Empty, NavLink } from "@/components/ui";
import { staffScreen } from "@/lib/screen";
import { shiftDateKey } from "@/lib/tz";
import ScheduleCalendar, { UNASSIGNED, type CalEvent, type Resource } from "./calendar";
import JumpToDate from "./jump";
import FillPanel from "./fill/panel";

export const dynamic = "force-dynamic";

/**
 * The timetable, as a calendar.
 *
 * THE RANGE AND THE NAVIGATION ARE THE SAME THING. They used to be two: the
 * fetch was `now - 7 days` to `now + 28 days` decided here at render time,
 * while moving between days was client state that never refetched — so every
 * date outside that 35-day window drew an empty grid. The date and the view are
 * in the URL now, this fetches exactly the days being shown, and navigating is
 * a server navigation.
 *
 * Owner and manager only — Decision 9 keeps the timetable with them.
 */
export default async function Schedule({
  searchParams,
}: { searchParams: { d?: string; view?: string } }) {
  const screen = await staffScreen("/schedule");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!["owner", "manager"].includes(ctx.role)) {
    return (
      <AppShell {...shell} title="Schedule">
        <Empty>
          The timetable is the owner&rsquo;s and managers&rsquo; to set. You are
          signed in as {ctx.role.replace("_", " ")}.
        </Empty>
      </AppShell>
    );
  }

  const view = searchParams.view === "week" ? "week" : "day";

  // The studio's today, not the server's. `now()::date` where this runs is a
  // different day from Manila's for most of the world's hours.
  const { data: todayData } = await supabase.rpc("studio_today", { p_studio_id: ctx.studioId });
  const today = (todayData as unknown as string) ?? new Date().toISOString().slice(0, 10);
  const anchor = /^\d{4}-\d{2}-\d{2}$/.test(searchParams.d ?? "") ? searchParams.d! : today;

  // A day either side of what is shown, so a class that runs past midnight and
  // the arrows both have something to land on.
  const [y, m, d] = anchor.split("-").map(Number);
  const dow = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
  const weekStart = view === "week" ? shiftDateKey(anchor, -((dow + 6) % 7)) : anchor;
  const from = shiftDateKey(weekStart, -1);
  const to = shiftDateKey(weekStart, view === "week" ? 7 : 1);

  const [{ data: instructors }, { data: rows, error: rangeError }, { data: pending },
         { data: settings },
         { data: quietPct }, { data: quietDays }, { data: fullPct }] =
    await Promise.all([
      supabase.from("instructors")
        .select("id, display_name").eq("status", "active").order("display_name"),
      // One reader, and the day boundary resolved inside it. Comparing UTC
      // instants against a date here would lose every class either side of
      // local midnight — which for Manila is every 07:00 class there is.
      supabase.rpc("schedule_range", { p_studio_id: ctx.studioId, p_from: from, p_to: to }),
      supabase.from("shift_applications")
        .select("occurrence_id").eq("status", "pending"),
      supabase.from("studio_settings")
        .select("unstaffed_deadline_hours").eq("studio_id", ctx.studioId).maybeSingle(),
      supabase.rpc("insight_threshold", { p_studio_id: ctx.studioId, p_key: "underfilled_pct" }),
      supabase.rpc("insight_threshold", { p_studio_id: ctx.studioId, p_key: "underfilled_window_days" }),
      supabase.rpc("insight_threshold", { p_studio_id: ctx.studioId, p_key: "overfilled_pct" }),
    ]);

  // A FAILED QUERY MUST NOT LOOK LIKE AN EMPTY WEEK. `schedule_range()` raised
  // on every call on hosted for a week — PostgREST returned the error, this
  // page read only `data`, and `rows ?? []` drew a blank grid that was
  // indistinguishable from a studio with no classes. The blankness was the bug
  // report; the error had been there the whole time and nothing showed it.
  if (rangeError) {
    return (
      <AppShell {...shell} title="Schedule">
        <div className="max-w-[62ch] border-l-[3px] px-3.5 py-3"
             style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}
             role="alert">
          <p className="text-[13px] leading-[19px] text-ink">
            The timetable could not be read, so this is not an empty week — it is
            a failure. Nothing has been changed.
          </p>
          <p className="num mt-2 break-words text-[12px] leading-[17px] text-ink-2">
            {rangeError.message}
          </p>
        </div>
      </AppShell>
    );
  }

  const deadlineHours = settings?.unstaffed_deadline_hours ?? 48;
  // Prefixed names: an OUT parameter called `id` shadows the column inside the
  // function, so schedule_range() returns occ_* and the page reads them.
  const occurrences = (rows ?? []) as unknown as {
    occ_id: string; occ_name: string; starts_at: string; ends_at: string;
    local_date: string; start_minutes: number; end_minutes: number;
    occ_instructor_id: string | null; room_name: string | null;
    occ_capacity: number; occ_booked: number; occ_waitlist: number; occ_staffing: string;
  }[];

  const appCount = new Map<string, number>();
  for (const a of pending ?? []) {
    appCount.set(a.occurrence_id, (appCount.get(a.occurrence_id) ?? 0) + 1);
  }

  // Unassigned first, deliberately: an open shift is the thing most likely to
  // need doing something about, so it is the column you read before the others.
  const resources: Resource[] = [
    { resourceId: UNASSIGNED, resourceTitle: "Unassigned" },
    ...(instructors ?? []).map((i) => ({
      resourceId: i.id, resourceTitle: i.display_name,
    })),
  ];

  const now = Date.now();
  const events: CalEvent[] = occurrences.map((o) => ({
    id: o.occ_id,
    title: o.occ_name,
    startsAt: o.starts_at,
    endsAt: o.ends_at,
    resourceId: o.occ_instructor_id ?? UNASSIGNED,
    staffing: (o.occ_staffing ?? "assigned") as CalEvent["staffing"],
    bookedCount: o.occ_booked,
    capacity: o.occ_capacity,
    waitlistCount: o.occ_waitlist ?? 0,
    room: o.room_name,
    pendingApplications: appCount.get(o.occ_id) ?? 0,
    hoursAway: (new Date(o.starts_at).getTime() - now) / 3_600_000,
  }));

  // THE VISIBLE HOURS COME FROM WHAT IS ON THE SCHEDULE, not from a constant.
  // A studio whose first class is 05:30 or whose last ends at 21:40 had them
  // silently outside the grid, and 06:00-22:00 was a guess about somebody
  // else's studio anyway. Computed from the studio-local minutes the reader
  // already resolved, so no timezone arithmetic happens in a browser.
  const inRange = occurrences.filter((o) => o.local_date >= weekStart);
  const earliest = inRange.length
    ? Math.min(...inRange.map((o) => o.start_minutes)) : 7 * 60;
  const latest = inRange.length
    ? Math.max(...inRange.map((o) => o.end_minutes)) : 20 * 60;
  const minHour = Math.max(0, Math.floor(earliest / 60) - 1);
  const maxHour = Math.min(24, Math.ceil(latest / 60) + 1);

  // Only asked when there is nothing to show, so the ordinary render costs
  // nothing. An empty calendar that cannot point at the timetable it is a view
  // of is indistinguishable from a broken one.
  type Elsewhere = { next: string | null; previous: string | null;
                     classes_that_day: number; has_any: boolean };
  let elsewhere: Elsewhere | null = null;
  if (events.length === 0) {
    const { data } = await supabase.rpc("next_class_day", {
      p_studio_id: ctx.studioId, p_from: weekStart,
    });
    elsewhere = data as unknown as Elsewhere;
  }

  const fmtDay = (d: string) =>
    new Intl.DateTimeFormat("en-GB", {
      weekday: "long", day: "numeric", month: "long", timeZone: ctx.timeZone,
    }).format(new Date(`${d}T12:00:00Z`));

  return (
    <AppShell {...shell} title="Schedule"
              actions={
                <>
                  <JumpToDate anchor={anchor} view={view} />
                  <NavLink href="/shifts/applications">Applications</NavLink>
                  <NavLink href="/classes/new">Add a class</NavLink>
                </>
              }>
      {resources.length > 1 && <FillPanel />}

      {events.length === 0 && (
        <p className="mb-4 max-w-[62ch] text-[13px] leading-[20px] text-ink-2">
          Nothing on {view === "week" ? "this week" : "this day"} in{" "}
          {ctx.timeZone.replace("_", " ")} — the studio&rsquo;s own clock, not yours.
          {elsewhere?.next ? (
            <>
              {" "}Your next classes are on{" "}
              <Link href={`/schedule?d=${elsewhere.next}&view=${view}`}
                    className="text-lime-text underline underline-offset-4">
                {fmtDay(elsewhere.next)}
              </Link>
              {elsewhere.classes_that_day > 0 && <> — {elsewhere.classes_that_day} of them</>}.
            </>
          ) : elsewhere?.previous ? (
            <>
              {" "}The last were on{" "}
              <Link href={`/schedule?d=${elsewhere.previous}&view=${view}`}
                    className="text-lime-text underline underline-offset-4">
                {fmtDay(elsewhere.previous)}
              </Link>
              . Nothing is scheduled ahead of today.
            </>
          ) : elsewhere && !elsewhere.has_any ? (
            <>
              {" "}This studio has no classes on its timetable at all yet.{" "}
              <Link href="/series" className="text-lime-text underline underline-offset-4">
                Add a recurring class
              </Link>{" "}
              and a year of them appears.
            </>
          ) : null}
        </p>
      )}

      {resources.length === 1 ? (
        <Empty>
          Add an instructor and your timetable will have columns to fill.{" "}
          <NavLink href="/instructors">Add one</NavLink>
        </Empty>
      ) : (
        <ScheduleCalendar
          events={events} resources={resources}
          timeZone={ctx.timeZone} deadlineHours={deadlineHours}
          quietPct={Number(quietPct ?? 0.4)}
          quietWindowDays={Number(quietDays ?? 7)}
          fullPct={Number(fullPct ?? 0.95)}
          anchor={anchor} today={today} view={view}
          minHour={minHour} maxHour={maxHour}
        />
      )}
    </AppShell>
  );
}
