import Link from "next/link";
import { AppShell, Empty, NavLink } from "@/components/ui";
import { staffScreen } from "@/lib/screen";
import { shiftDateKey, studioDateKey, studioToday } from "@/lib/tz";
import ScheduleCalendar, { UNASSIGNED, type CalEvent, type Resource } from "./calendar";
import JumpToDate from "./jump";
import InstructorFilter from "./instructor-filter";
import ShowAllToggle from "./show-all-toggle";
import FillPanel from "./fill/panel";
import PublishForm from "@/app/staff/publish/publish-form";

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
}: { searchParams: { d?: string; view?: string; all?: string; instructor?: string } }) {
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

  const view = searchParams.view === "week" ? "week"
    : searchParams.view === "month" ? "month" : "day";
  // The instructor filter: "" = all, an id, or "unassigned". It applies across
  // all three views and travels with every navigation.
  const instructorFilter = typeof searchParams.instructor === "string" ? searchParams.instructor : "";

  // The studio's today, not the server's — `now()` where this runs is a
  // different day from Manila's for most of the world's hours. COMPUTED rather
  // than fetched: this was a whole serial round trip that had to finish before
  // the page could even name the day it was about to ask for. Intl carries the
  // same IANA rules Postgres does; checked against hosted, both say 2026-09-10
  // for Asia/Manila while the server's own date is the 9th.
  const today = studioToday(ctx.timeZone);
  const anchor = /^\d{4}-\d{2}-\d{2}$/.test(searchParams.d ?? "") ? searchParams.d! : today;

  // WHICH DAY A WEEK STARTS ON IS THE STUDIO'S, AND BOTH SIDES MUST AGREE.
  // This hardcoded Monday while react-big-calendar rendered Sunday-first — its
  // localizer is handed date-fns' bare startOfWeek, which defaults to Sunday
  // when no locale reaches it. With an anchor on a Sunday the server then
  // fetched the Monday-based week BEHIND it while the grid drew the
  // Sunday-based week starting at it: two days of overlap, five columns empty,
  // and a refresh could not help because nothing was stale — it was simply the
  // wrong week. `week_starts_on` has been a setting since migration 001 and
  // neither side was reading it.
  // From the staff context, which every screen already fetches — not a
  // second round trip in front of the range this decides.
  const weekStartsOn = ctx.weekStartsOn;
  const [y, m, d] = anchor.split("-").map(Number);
  const dow = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
  // The fetch window and the banner's range, per view. `from`/`to` cover what
  // the grid draws — a day either side for day/week so a class past midnight and
  // the arrows have something to land on, the whole six-week grid for month.
  // `rangeStart`/`rangeEnd` is what the unstaffed banner counts over: the day,
  // the week, or the calendar month.
  let from: string, to: string, weekStart: string, rangeStart: string, rangeEnd: string;
  if (view === "month") {
    const monthFirst = `${y}-${String(m).padStart(2, "0")}-01`;
    const firstDow = new Date(Date.UTC(y, m - 1, 1)).getUTCDay();
    const daysInMonth = new Date(Date.UTC(y, m, 0)).getUTCDate();
    const gridStart = shiftDateKey(monthFirst, -(((firstDow - weekStartsOn) + 7) % 7));
    weekStart = gridStart;
    from = shiftDateKey(gridStart, -1);
    to = shiftDateKey(gridStart, 42);
    rangeStart = monthFirst;
    rangeEnd = `${y}-${String(m).padStart(2, "0")}-${String(daysInMonth).padStart(2, "0")}`;
  } else {
    weekStart = view === "week"
      ? shiftDateKey(anchor, -(((dow - weekStartsOn) + 7) % 7))
      : anchor;
    from = shiftDateKey(weekStart, -1);
    to = shiftDateKey(weekStart, view === "week" ? 7 : 1);
    rangeStart = weekStart;
    rangeEnd = shiftDateKey(weekStart, view === "week" ? 6 : 0);
  }

  const [{ data: classTypes }, { data: rooms },
         { data: instructors }, { data: rows, error: rangeError }, { data: pending },
         { data: settings },
         { data: quietPct }, { data: quietDays }, { data: fullPct },
         { data: elsewhereData }] =
    await Promise.all([
      supabase.from("class_types")
      .select("id, name, duration_minutes, default_capacity")
      .eq("status", "active").order("name"),
    supabase.from("rooms")
      .select("id, name, capacity").eq("status", "active").order("name"),
    supabase.from("instructors")
        .select("id, display_name, avatar_url").eq("status", "active").order("display_name"),
      // One reader, and the day boundary resolved inside it. Comparing UTC
      // instants against a date here would lose every class either side of
      // local midnight — which for Manila is every 07:00 class there is.
      supabase.rpc("schedule_range", { p_studio_id: ctx.studioId, p_from: from, p_to: to }),
      supabase.from("shift_applications")
        .select("occurrence_id").eq("status", "pending"),
      supabase.from("studio_settings")
        .select("unstaffed_deadline_hours, week_starts_on, guarantees_enabled, flex_enabled")
        .eq("studio_id", ctx.studioId).maybeSingle(),
      supabase.rpc("insight_threshold", { p_studio_id: ctx.studioId, p_key: "underfilled_pct" }),
      supabase.rpc("insight_threshold", { p_studio_id: ctx.studioId, p_key: "underfilled_window_days" }),
      supabase.rpc("insight_threshold", { p_studio_id: ctx.studioId, p_key: "overfilled_pct" }),
      supabase.rpc("next_class_day", { p_studio_id: ctx.studioId, p_from: weekStart }),
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
    occ_flex: boolean; occ_confirmed: boolean;
    occ_tier: string | null; occ_standalone: boolean | null;
    occ_series_tier: string | null; occ_minimum: number | null;
    occ_status: string; occ_cancellation_cause: string | null;
  }[];

  const appCount = new Map<string, number>();
  for (const a of pending ?? []) {
    appCount.set(a.occurrence_id, (appCount.get(a.occurrence_id) ?? 0) + 1);
  }

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
    // Decision 21. Only meaningful BEFORE the decision: once confirmed a flex
    // class is an ordinary class and drawing it differently would be marking a
    // distinction that has stopped existing.
    flexPending: o.occ_flex && !o.occ_confirmed,
    // TWO FACTS, kept apart. `tier` is what the class IS — what the studio
    // configured, and what the series list beside this screen shows. `effective`
    // is what it will DO once the studio's switches are applied. They differ
    // whenever a tier's switch is off, which is Reform Collective today.
    tier: o.occ_series_tier ?? null,
    effectiveTier: o.occ_tier ?? null,
    minimum: o.occ_minimum ?? null,
    // A flex slot with nothing else of that instructor's beside it: the one
    // that costs a trip for a class that may not run, and the one a studio
    // should look at twice before putting it there.
    standalone: (o.occ_standalone ?? false) && !o.occ_confirmed,
    // A flex class the cutoff cancelled for want of its minimum. schedule_range
    // keeps it (migration 116) so the slot that cancels week after week is
    // visible; the calendar draws it not-running with the count that decided it.
    notRunning: o.occ_status === "cancelled" && o.occ_cancellation_cause === "unmet_minimum",
  }));

  // The instructor filter narrows what the calendar DRAWS — a specific
  // instructor keeps their classes, "Unassigned only" keeps the gaps (the view
  // a studio uses to fill a month), "" keeps everything. Day view also narrows
  // the columns (below). The unstaffed banner is NOT filtered by instructor — it
  // is a range-level fact (see below).
  const filteredEvents =
    instructorFilter === "" ? events
    : instructorFilter === "unassigned" ? events.filter((e) => e.staffing !== "assigned")
    : events.filter((e) => e.resourceId === instructorFilter);

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

  // Fetched in the batch above rather than behind an `if`: it used to be a
  // FOURTH serial hop that fired only when the day was empty, which is exactly
  // the render that was already slowest to say anything useful.
  type Elsewhere = { next: string | null; previous: string | null;
                     classes_that_day: number; has_any: boolean };
  const elsewhere = elsewhereData as unknown as Elsewhere | null;

  const fmtDay = (d: string) =>
    new Intl.DateTimeFormat("en-GB", {
      weekday: "long", day: "numeric", month: "long", timeZone: ctx.timeZone,
    }).format(new Date(`${d}T12:00:00Z`));

  // Unassigned first, deliberately: an open shift is the thing most likely to
  // need doing something about, so it is the column you read before the others.
  const everyone: Resource[] = [
    { resourceId: UNASSIGNED, resourceTitle: "Unassigned" },
    ...(instructors ?? []).map((i) => ({
      resourceId: i.id, resourceTitle: i.display_name,
    })),
  ];

  // ONLY THE PEOPLE ACTUALLY TEACHING, unless asked otherwise.
  //
  // A column per instructor does not scale and was never tested past three. Six
  // instructors is seven columns; twelve is thirteen, and on a quiet day every
  // one of them reads "Free all day" — thirteen columns saying nothing, with the
  // grid cut mid-column at the right edge. The day's own classes decide which
  // columns exist.
  //
  // `?all=1` puts everyone back, and it has to exist: dragging a class onto
  // somebody who is not teaching yet is how a class gets assigned, and a column
  // that is not there cannot be dropped on.
  // CLASSES IN THE VISIBLE RANGE WITH NOBODY TEACHING THEM, said once at the top
  // rather than left to be found by scanning amber blocks — in every view,
  // scoped to whatever range is showing (the day, the week, or the calendar
  // month). It AGREES with the Morning Brief's `unstaffed_class` insight rather
  // than counting differently: same definition (scheduled, staffing not
  // assigned, still in the future), and the members-booked subset — which is
  // what the brief raises however far away — is called out. It is a range-level
  // fact and is NOT narrowed by the instructor filter, so "where are my gaps"
  // stays answered even while looking at one person.
  const unstaffed = occurrences
    .filter((o) =>
      o.occ_status === "scheduled" &&
      (o.occ_staffing ?? "assigned") !== "assigned" &&
      o.local_date >= rangeStart && o.local_date <= rangeEnd &&
      new Date(o.starts_at).getTime() > now)
    .sort((a, b) => a.starts_at.localeCompare(b.starts_at));
  const unstaffedBooked = unstaffed.filter((o) => o.occ_booked > 0).length;
  const hhmm = (mins: number) =>
    `${String(Math.floor(mins / 60)).padStart(2, "0")}:${String(mins % 60).padStart(2, "0")}`;
  const shortDay = (isoDate: string) =>
    new Intl.DateTimeFormat("en-GB", { weekday: "short", day: "numeric", month: "short", timeZone: ctx.timeZone })
      .format(new Date(`${isoDate}T12:00:00Z`));

  // PUBLICATION STATE for the month(s) the visible range covers. Decision 25:
  // members can see and book only published months, so a studio looking at a full
  // calendar of a DRAFT month and assuming it is live is exactly the failure to
  // prevent. Only relevant when the studio builds months as drafts — with
  // publication off, every month is live the moment its classes exist, so there
  // is nothing to say and no control to show. A week can cross a month boundary,
  // so the range may span two months in two different states.
  type PubFacts = {
    month: string; label: string; published: boolean;
    classes: number; open_shifts: number;
    instructors: { instructor_id: string; name: string; classes: number; reachable: boolean }[];
  };
  let pubMonths: PubFacts[] = [];
  if (ctx.publicationEnabled) {
    // Which months, of those the range covers, actually have classes on screen —
    // a banner about a month with nothing visible is noise.
    const monthsWithClasses = new Set(
      occurrences
        .filter((o) => o.local_date >= rangeStart && o.local_date <= rangeEnd && o.occ_status === "scheduled")
        .map((o) => o.local_date.slice(0, 7)));
    const candKeys = Array.from(new Set([rangeStart.slice(0, 7), rangeEnd.slice(0, 7)]))
      .filter((k) => monthsWithClasses.has(k));
    const previews = await Promise.all(
      candKeys.map((k) => supabase.rpc("publish_month_preview", { p_studio_id: ctx.studioId, p_month: `${k}-01` })));
    pubMonths = previews
      .map((p) => p.data as unknown as PubFacts | null)
      .filter((f): f is PubFacts => !!f)
      .sort((a, b) => a.month.localeCompare(b.month));
  }
  const draftMonths = pubMonths.filter((m) => !m.published);
  const publishedInView = pubMonths.filter((m) => m.published);
  // "November" / "November and December" / "October, November and December".
  const listAnd = (xs: string[]) =>
    xs.length <= 1 ? (xs[0] ?? "")
    : `${xs.slice(0, -1).join(", ")} and ${xs[xs.length - 1]}`;

  const showAll = searchParams.all === "1";
  // THE ANCHOR DAY ONLY. The fetch deliberately spans a day either side, so
  // counting every event in `events` puts a column up for somebody who teaches
  // tomorrow and shows it empty — the same "column saying nothing" in a new
  // place. Measured: three columns for a day with two classes.
  const busy = new Set(
    events
      .filter((e) => studioDateKey(new Date(e.startsAt), ctx.timeZone) === anchor)
      .map((e) => e.resourceId),
  );
  // A filter decides the day columns directly: one instructor is their column,
  // "unassigned" is the Unassigned column, and only then does the busy/show-all
  // logic apply.
  const shown: Resource[] =
    instructorFilter && instructorFilter !== "unassigned"
      ? everyone.filter((r) => r.resourceId === instructorFilter)
    : instructorFilter === "unassigned"
      ? everyone.filter((r) => r.resourceId === UNASSIGNED)
    : showAll ? everyone : everyone.filter((r) => busy.has(r.resourceId));
  const hiddenCount = everyone.length - shown.length;


  return (
    <AppShell {...shell} title="Schedule"
              actions={
                <>
                  {everyone.length > 1 && (
                    <InstructorFilter anchor={anchor} view={view} value={instructorFilter}
                                      instructors={instructors ?? []} />
                  )}
                  {/* Decision 37: the teaching-today / everyone default, made a
                      visible toggle. Only on Day (columns exist there) and only
                      when a specific instructor is not already filtered to. */}
                  {view === "day" && everyone.length > 1 && !instructorFilter && (
                    <ShowAllToggle anchor={anchor} view={view} showAll={showAll} instructor={instructorFilter} />
                  )}
                  <JumpToDate anchor={anchor} view={view} instructor={instructorFilter} />
                  <NavLink href="/schedule/flex">Flex</NavLink>
                  <NavLink href="/shifts/applications">Applications</NavLink>
                  <NavLink href="/classes/new">Add a class</NavLink>
                </>
              }>
      {everyone.length > 1 && <FillPanel />}

      {/* PUBLICATION STATE — the most important thing to know about a month you
          are looking at, so it sits above everything else. Draft is loud (coral):
          a full calendar members cannot book is worse than one that is simply
          empty. A range spanning two states names both. */}
      {ctx.publicationEnabled && draftMonths.length > 0 && (
        <div className="mb-4 max-w-[64ch] rounded border-l-[3px] px-3.5 py-3"
             style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }} role="alert">
          <p className="text-[13px] leading-[19px] text-ink">
            <span className="font-semibold">
              {listAnd(draftMonths.map((m) => m.label))}{" "}
              {draftMonths.length === 1 ? "is" : "are"} not published
            </span>{" "}
            — members cannot see or book {draftMonths.length === 1 ? "these classes" : "any of these classes"}.
          </p>
          {publishedInView.length > 0 && (
            <p className="mt-1 text-[12.5px] leading-[18px] text-ink-2">
              This {view} also covers {listAnd(publishedInView.map((m) => m.label))}, which{" "}
              {publishedInView.length === 1 ? "is" : "are"} published.
            </p>
          )}
          {/* The publish control, on the same screen, for the month being viewed
              — with the preview: how many classes, how many unstaffed, how many
              instructors. Pressing it publishes and confirms on /publish. */}
          <div className="mt-3 space-y-3">
            {draftMonths.map((m) => (
              <div key={m.month} className="rounded border border-line bg-surface p-3">
                <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
                  <span className="text-[13px] font-medium leading-[18px] text-ink">{m.label}</span>
                  <span className="num text-[12px] leading-4 text-ink-2">
                    {m.classes} {m.classes === 1 ? "class" : "classes"}
                    {m.open_shifts > 0 && ` · ${m.open_shifts} unstaffed`}
                    {` · ${m.instructors.length} ${m.instructors.length === 1 ? "instructor" : "instructors"}`}
                  </span>
                </div>
                <PublishForm month={m.month} label={m.label}
                  openShifts={m.open_shifts}
                  unreachable={m.instructors.filter((i) => !i.reachable).map((i) => i.name)} />
              </div>
            ))}
          </div>
        </div>
      )}
      {/* All of what is on screen is published — a quiet confirmation, not a
          demand for attention. */}
      {ctx.publicationEnabled && draftMonths.length === 0 && publishedInView.length > 0 && (
        <p className="mb-4 text-[12.5px] leading-[18px] text-ink-3">
          {listAnd(publishedInView.map((m) => m.label))}{" "}
          {publishedInView.length === 1 ? "is" : "are"} published — members can see and book{" "}
          {publishedInView.length === 1 ? "it" : "them"}.
        </p>
      )}

      {/* Nobody teaching them — the count made visible without scanning the
          grid. Amber on a block is easy to miss across a week; a sentence with
          the classes named and linked is not. Each links to its roster, where
          the Assign control lives. */}
      {unstaffed.length > 0 && (
        <div className="mb-4 max-w-[62ch] rounded border-l-[3px] px-3.5 py-3"
             style={{ borderLeftColor: "var(--amber-deep)", background: "var(--amber-tint)" }}>
          <p className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">
              <span className="num">{unstaffed.length}</span>{" "}
              {unstaffed.length === 1 ? "class" : "classes"}{" "}
              {view === "week" ? "this week" : view === "month" ? "this month" : "this day"}{" "}
              {unstaffed.length === 1 ? "has" : "have"} nobody teaching {unstaffed.length === 1 ? "it" : "them"}.
            </span>
            {unstaffedBooked > 0 && (
              <>
                {" "}
                <span className="num">{unstaffedBooked}</span>{" "}
                {unstaffedBooked === 1 ? "has" : "have"} members already booked.
              </>
            )}
          </p>
          <ul className="mt-2 flex flex-wrap gap-x-4 gap-y-1">
            {unstaffed.map((o) => (
              <li key={o.occ_id} className="text-[12.5px] leading-[18px]">
                <Link href={`/roster/${o.occ_id}`}
                      className="text-ink underline decoration-line-2 underline-offset-4 hover:decoration-ink">
                  {o.occ_name}
                </Link>
                <span className="num text-ink-3">
                  {" "}· {shortDay(o.local_date)} {hhmm(o.start_minutes)}
                  {o.occ_booked > 0 ? ` · ${o.occ_booked} booked` : ""}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}

      {filteredEvents.length === 0 && instructorFilter && (
        // A filter narrowed the range to nothing — a real state, distinct from
        // the studio having no classes. The elsewhere guidance below is about
        // the whole timetable and would mislead here, so it is not shown.
        <p className="mb-4 max-w-[62ch] text-[13px] leading-[20px] text-ink-2">
          No classes for{" "}
          {instructorFilter === "unassigned"
            ? "unassigned slots"
            : (instructors ?? []).find((i) => i.id === instructorFilter)?.display_name ?? "that instructor"}{" "}
          {view === "week" ? "this week" : view === "month" ? "this month" : "on this day"}.{" "}
          <Link href={`/schedule?d=${anchor}&view=${view}`}
                className="text-lime-text underline underline-offset-4">
            Show all instructors
          </Link>
        </p>
      )}

      {events.length === 0 && !instructorFilter && (
        <p className="mb-4 max-w-[62ch] text-[13px] leading-[20px] text-ink-2">
          Nothing on {view === "week" ? "this week" : view === "month" ? "this month" : "this day"} in{" "}
          {ctx.timeZone.replace("_", " ")} — the studio&rsquo;s own clock, not yours.
          {view === "day" && everyone.length > 1 && (
            <>
              {" "}Nobody is teaching on this day.{" "}
              <Link href={`/schedule?d=${anchor}&view=day&all=1`}
                    className="text-lime-text underline underline-offset-4">
                Show all {everyone.length - 1} instructors
              </Link>{" "}
              to put somebody on.
            </>
          )}
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

      {/* WHO IS SHOWING, and how to see the rest. A day view whose columns are
          only the people teaching is unreadable in a different way if it never
          says so: an owner would think the others had been removed. */}
      {view === "day" && everyone.length > 1 && shown.length > 0 && !instructorFilter && (
        <p className="mb-3 text-[12.5px] leading-[18px] text-ink-2">
          {showAll ? (
            <>
              Showing all <span className="num">{everyone.length - 1}</span> instructors.{" "}
              <Link href={`/schedule?d=${anchor}&view=day`}
                    className="text-lime-text underline underline-offset-4">
                Show only who is teaching
              </Link>
            </>
          ) : hiddenCount > 0 ? (
            <>
              Showing the{" "}
              <span className="num">{shown.filter((r) => r.resourceId !== UNASSIGNED).length}</span>{" "}
              {shown.filter((r) => r.resourceId !== UNASSIGNED).length === 1
                ? "instructor" : "instructors"} teaching on this day.{" "}
              <Link href={`/schedule?d=${anchor}&view=day&all=1`}
                    className="text-lime-text underline underline-offset-4">
                Show all {everyone.length - 1}
              </Link>{" "}
              <span className="text-ink-3">— needed to assign a class to somebody free.</span>
            </>
          ) : (
            <>Every instructor is teaching on this day.</>
          )}
        </p>
      )}

      {everyone.length === 1 ? (
        <Empty>
          Add an instructor and your timetable will have columns to fill.{" "}
          <NavLink href="/instructors">Add one</NavLink>
        </Empty>
      ) : view === "day" && shown.length === 0 ? (
        // SAID ONCE, in the message above. An empty grid with no columns is
        // worse than no grid, and a second block repeating the same sentence is
        // how a screen starts shouting.
        null
      ) : (
        <ScheduleCalendar
          events={filteredEvents} resources={shown}
          classTypes={classTypes ?? []} rooms={rooms ?? []}
          timeZone={ctx.timeZone} deadlineHours={deadlineHours}
          quietPct={Number(quietPct ?? 0.4)}
          quietWindowDays={Number(quietDays ?? 7)}
          fullPct={Number(fullPct ?? 0.95)}
          // Decision 22's two switches, OR'd — the same condition as the tier
          // control. A studio using neither sees no mark and no extra sentence
          // in the legend.
          showTier={(settings?.guarantees_enabled ?? false) || (settings?.flex_enabled ?? false)}
          coreEnabled={settings?.guarantees_enabled ?? false}
          flexEnabled={settings?.flex_enabled ?? false}
          anchor={anchor} today={today} view={view} weekStartsOn={weekStartsOn}
          minHour={minHour} maxHour={maxHour}
          // id -> name and id -> avatar for EVERY active instructor, so the week
          // block and the panel can show whoever teaches a class even when their
          // column is hidden. Instructor avatars are public URLs (no signing).
          instructorNames={Object.fromEntries((instructors ?? []).map((i) => [i.id, i.display_name]))}
          instructorAvatars={Object.fromEntries((instructors ?? []).map((i) => [i.id, i.avatar_url ?? null]))}
          // The active instructor filter, carried through the calendar's own
          // navigations (Back/Next/Today, the view toggle, drilling into a day).
          instructorParam={instructorFilter}
          // This screen is owner/manager-only (gated above), so the caller can
          // always staff a class from the panel.
          canManage
        />
      )}
    </AppShell>
  );
}
