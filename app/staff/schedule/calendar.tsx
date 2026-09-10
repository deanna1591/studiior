"use client";

import { useCallback, useEffect, useMemo, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Calendar, Views, dateFnsLocalizer, type View } from "react-big-calendar";
import withDragAndDrop from "react-big-calendar/lib/addons/dragAndDrop";
import { format, parse, startOfWeek, getDay } from "date-fns";
import { enGB } from "date-fns/locale";
import { moveClass } from "./actions";
import CreateOnSlot, { type SlotDraft } from "./create-slot";
import { toStudioWall, fromStudioWall, wallAt, shiftDateKey, studioDateKey } from "@/lib/tz";
import "react-big-calendar/lib/css/react-big-calendar.css";
import "react-big-calendar/lib/addons/dragAndDrop/styles.css";

// Typed on the WALL shape, because that is what the grid is handed: a CalEvent
// carries instants and gains its two Dates in lib/tz's projection.
const DnDCalendar = withDragAndDrop<WallEvent, Resource>(Calendar as never);

/**
 * WHICH DAY THE WEEK STARTS ON IS THE STUDIO'S.
 *
 * This used to be one module-level localizer handed date-fns' bare
 * `startOfWeek`, which defaults to SUNDAY when no locale reaches it — and
 * react-big-calendar passes none unless the Calendar carries a `culture`. So
 * the grid drew Sunday-first while the page fetched a Monday-based week, and
 * `studio_settings.week_starts_on` — a column since migration 001 — decided
 * nothing at all. An anchor landing on a Sunday then had the server fetch the
 * week BEHIND the one on screen: two days of overlap and five empty columns,
 * with a refresh unable to help because nothing was stale.
 *
 * Built per studio and memoised, because a new localizer object on every
 * render remounts react-big-calendar's internals.
 */
function makeLocalizer(weekStartsOn: number) {
  const w = ((weekStartsOn % 7) + 7) % 7 as 0 | 1 | 2 | 3 | 4 | 5 | 6;
  return dateFnsLocalizer({
    format, parse, getDay, locales: { "en-GB": enGB },
    startOfWeek: (date: Date) => startOfWeek(date, { weekStartsOn: w }),
  });
}

// 24-hour, like every other time in the product. react-big-calendar's default
// is the locale's, which gave "3:30 PM" beside a roster reading "15:30".
const formats = {
  timeGutterFormat: "HH:mm",
  eventTimeRangeFormat: ({ start, end }: { start: Date; end: Date }) =>
    `${format(start, "HH:mm")}–${format(end, "HH:mm")}`,
  selectRangeFormat: ({ start, end }: { start: Date; end: Date }) =>
    `${format(start, "HH:mm")}–${format(end, "HH:mm")}`,
  dayRangeHeaderFormat: ({ start, end }: { start: Date; end: Date }) =>
    `${format(start, "d MMM")} – ${format(end, "d MMM yyyy")}`,
  dayHeaderFormat: "EEEE d MMMM yyyy",
};

/** The left-hand column. A sentinel rather than null: a resource needs an id. */
export const UNASSIGNED = "unassigned";

export type Resource = { resourceId: string; resourceTitle: string };
export type CalEvent = {
  id: string;
  title: string;
  /** The real instants, ISO. NOT what the grid lays out — see lib/tz.ts. */
  startsAt: string;
  endsAt: string;
  resourceId: string;
  staffing: "assigned" | "open" | "pending_approval";
  bookedCount: number;
  capacity: number;
  waitlistCount: number;
  /** Hours from now until it starts, so "approaching" can be decided here. */
  hoursAway: number;
  room: string | null;
  pendingApplications: number;
  /** Decision 21: flex and not yet decided. False once confirmed. */
  flexPending: boolean;
  tier: string | null;
  standalone: boolean;
};

/** A CalEvent with the two Dates the grid lays out, in studio wall time. */
type WallEvent = CalEvent & { start: Date; end: Date };

export default function ScheduleCalendar({
  events: initial, resources, classTypes, rooms, timeZone, deadlineHours,
  quietPct, quietWindowDays, fullPct,
  anchor, today, view, minHour, maxHour, weekStartsOn,
}: {
  events: CalEvent[];
  resources: Resource[];
  /** For the slot-click form. Empty means the studio has none yet. */
  classTypes: { id: string; name: string; duration_minutes: number; default_capacity: number }[];
  rooms: { id: string; name: string; capacity: number }[];
  timeZone: string;
  deadlineHours: number;
  /** §11's own thresholds, passed in so the calendar and the brief agree. */
  quietPct: number;
  quietWindowDays: number;
  fullPct: number;
  /** The studio-local day being shown, and the studio's own today. */
  anchor: string;
  today: string;
  view: "day" | "week";
  /** 0 = Sunday .. 6 = Saturday, the studio's own. The grid and the query
   *  behind it must not disagree about which seven days a week is. */
  weekStartsOn: number;
  /** Derived from what is actually on the schedule, in studio time. */
  minHour: number;
  maxHour: number;
}) {
  // The date and the view are URL state, not component state. They decide which
  // days are FETCHED, and holding them here is what made every month outside a
  // fixed 35-day window render as an empty grid.
  //
  // EVENTS ARE STATE ONLY SO A DRAG CAN MOVE ONE BEFORE THE SERVER ANSWERS,
  // AND THAT COST A WEEK OF THE CALENDAR. `useState(initial)` reads its
  // argument on the first render of a component INSTANCE and never again;
  // navigating to another week is a router.push, which re-renders this
  // component rather than remounting it. So the grid moved to the new week
  // while `events` still held the old one, and the only classes that survived
  // were the ones in the overlap — the day-either-side padding, which is the
  // Sunday and Monday at the end of the previous fetch. A browser refresh
  // "fixed" it because a fresh mount is the one thing that re-reads `initial`.
  //
  // Reset during render rather than in an effect: React re-runs the component
  // immediately and never commits the stale output, so there is no frame
  // showing last week's classes under this week's dates. An effect would show
  // that frame every time.
  const localizer = useMemo(() => makeLocalizer(weekStartsOn), [weekStartsOn]);
  const [events, setEvents] = useState(initial);
  const [lastServed, setLastServed] = useState(initial);
  if (initial !== lastServed) {
    setLastServed(initial);
    setEvents(initial);
  }
  const [notice, setNotice] = useState<string | null>(null);
  const [blockedBy, setBlockedBy] = useState<
    { occurrenceId: string; name: string; at: string; who: string | null; room: string | null } | null
  >(null);
  // isPending is the whole point of the transition. Without it `router.push`
  // blocks on a server round trip with NOTHING on screen saying so — click
  // Next, nothing moves, then everything swaps at once. Inside a transition
  // React keeps the CURRENT grid mounted until the new one is ready, which is
  // what stops a populated day ever flashing as an empty one.
  const [isPending, startTransition] = useTransition();
  const router = useRouter();
  const go = useCallback((d: string, v: "day" | "week") => {
    startTransition(() => {
      router.push(`/schedule?d=${d}&view=${v}`);
    });
  }, [router]);

  // Back and Next are one round trip away, so pay for them before they are
  // pressed. Measured first: server work for a whole day is ~14 ms and a round
  // trip from here is ~58 ms, so the wait is latency and nothing else — which
  // is exactly the kind a prefetch removes and a faster query would not.
  useEffect(() => {
    const step = view === "week" ? 7 : 1;
    router.prefetch(`/schedule?d=${shiftDateKey(anchor, -step)}&view=${view}`);
    router.prefetch(`/schedule?d=${shiftDateKey(anchor, step)}&view=${view}`);
  }, [router, anchor, view]);

  // THE ONE PLACE THE ZONE IS APPLIED. react-big-calendar lays out Dates by
  // their browser-local fields, so it is handed Dates whose local fields have
  // been set to the studio's wall clock. Nothing below this line is a real
  // instant; `apply()` converts back before anything is saved.
  const wallEvents: WallEvent[] = useMemo(() => events.map((e) => ({
    ...e,
    start: toStudioWall(new Date(e.startsAt), timeZone),
    end: toStudioWall(new Date(e.endsAt), timeZone),
  })), [events, timeZone]);

  // The roster is built and knows about photos, pinned notes and check-in
  // state; the calendar links to it rather than growing a second one. A drag
  // does not fire this — react-big-calendar's DnD addon separates the two.
  const openRoster = useCallback((e: CalEvent) => {
    router.push(`/roster/${e.id}`);
  }, [router]);

  // Optimistic, and reverted the moment the database says no. The calendar is
  // a view of what move_occurrence() allows, never a second opinion about it.
  const apply = useCallback(
    async (
      ev: CalEvent, start: Date, end: Date, resourceId: string | undefined,
      confirm = false,
    ) => {
      const target = resourceId ?? ev.resourceId;
      const before = events;
      setNotice(null);

      // NOTHING moves on screen until the answer comes back. The first version
      // moved the class optimistically and then reverted it if the database
      // refused — which meant an accidental two-pixel drag visibly relocated a
      // class with eight people in it before anyone was asked. The class stays
      // where it is until we know.
      if (confirm) {
        setEvents(events.map((e) =>
          e.id === ev.id
            ? { ...e, startsAt: fromStudioWall(start, timeZone).toISOString(),
                endsAt: fromStudioWall(end, timeZone).toISOString(), resourceId: target }
            : e));
      }

      // Back to real instants. The grid handed us studio wall time; the
      // database has never wanted anything but the instant.
      const realStart = fromStudioWall(start, timeZone);
      const realEnd = fromStudioWall(end, timeZone);

      const res = await moveClass({
        occurrenceId: ev.id,
        startsAt: realStart.toISOString(),
        endsAt: realEnd.toISOString(),
        instructorId: target === UNASSIGNED ? null : target,
        confirm,
      });

      if (res.ok) {
        setEvents(events.map((e) =>
          e.id === ev.id
            ? { ...e, startsAt: realStart.toISOString(),
                endsAt: realEnd.toISOString(), resourceId: target }
            : e));
        const bits: string[] = [];
        if (res.warnings.includes("outside_availability")) {
          // Decision 9: permitted, and said out loud.
          bits.push("that is outside the availability they gave us");
        }
        if (res.significant) {
          bits.push("everyone booked can now cancel without penalty, because the time they agreed to has changed");
        }
        if (bits.length) setNotice(`Moved — ${bits.join(", and ")}.`);
        // The move already updated `events` locally; this only asks the server
        // for anything else that changed with it.
        startTransition(() => { router.refresh(); });
        return;
      }

      if (res.kind === "confirm") {
        const n = res.bookedCount;
        const yes = window.confirm(
          `This class has ${n} member${n === 1 ? "" : "s"} booked.\n\n` +
          `Moving it will email ${n === 1 ? "them" : "all ${n} of them"} to say the time has changed.\n\n` +
          `Move it back within a minute and no email goes out at all.`,
        );
        if (yes) return apply(ev, start, end, target, true);
        setEvents(before);
        return;
      }

      setNotice(res.message);
      setBlockedBy(res.blockedBy ?? null);
      setEvents(before);
    },
    [events, timeZone],
  );

  const onDrop = useCallback(
    ({ event, start, end, resourceId }: {
      event: CalEvent; start: Date | string; end: Date | string; resourceId?: string | number;
    }) => apply(event, new Date(start), new Date(end),
                resourceId === undefined ? undefined : String(resourceId)),
    [apply],
  );

  const onResize = useCallback(
    ({ event, start, end }: { event: CalEvent; start: Date | string; end: Date | string }) =>
      apply(event, new Date(start), new Date(end), event.resourceId),
    [apply],
  );

  // Colour carries the one thing you scan a timetable for: is anybody teaching
  // this. Everything else is text — a rainbow by class type would drown it.
  //
  // FULLNESS IS THE OTHER THING A PLANNER READS, and it is decided once here so
  // the fill, the label and the tooltip cannot disagree. The thresholds are
  // §11's own — the Morning Brief already says what "underfilled" means, and a
  // second definition on this screen would agree with it exactly once.
  const fullness = useCallback((e: CalEvent) => {
    if (e.capacity <= 0) return "unknown" as const;
    const share = e.bookedCount / e.capacity;
    if (e.bookedCount >= e.capacity) return "full" as const;
    if (share >= fullPct) return "nearly_full" as const;
    // "Quiet" only means something while there is still time to act on it. A
    // class three days out at two of eight is a decision; the same class in
    // five weeks is just early.
    if (share < quietPct && e.hoursAway > 0 && e.hoursAway <= quietWindowDays * 24) {
      return "quiet" as const;
    }
    return "ok" as const;
  }, [quietPct, quietWindowDays, fullPct]);

  const eventPropGetter = useCallback((e: WallEvent) => {
    const unstaffed = e.staffing !== "assigned";
    const waiting = e.staffing === "pending_approval";
    // The single worst state in the timetable: people are coming, the deadline
    // is close, and nobody has agreed to teach it. Given the hatching used for
    // "something is wrong here" elsewhere, plus coral, plus a marker in the
    // label — a slightly different pastel would not carry it.
    const alarming = unstaffed && e.bookedCount > 0 && e.hoursAway <= deadlineHours;
    // Staffing outranks fullness: nobody teaching it is a bigger problem than
    // nobody in it, and two loud states on one block is neither.
    const f = fullness(e);
    return {
      className: alarming ? "hatched" : undefined,
      style: {
        background: alarming ? "var(--coral-tint)"
                    : unstaffed ? "var(--amber-tint)"
                    : f === "quiet" ? "var(--surface)" : "var(--lime-tint)",
        borderLeft: `3px solid ${alarming ? "var(--coral)"
                    : waiting ? "var(--amber-deep)"
                    : unstaffed ? "var(--amber-deep)"
                    : f === "quiet" ? "var(--ink-3)" : "var(--lime-text)"}`,
        // A full class is closed, and the ring says so without another colour:
        // the palette's loud slots are spent on staffing.
        boxShadow: f === "full" || f === "nearly_full"
          ? "inset 0 0 0 1.5px var(--lime-text)" : undefined,
        // A flex class awaiting its deadline reads as provisional: a dashed
        // edge, which is the same vocabulary the no-room block uses for "this
        // is not settled yet".
        outline: e.flexPending ? "1px dashed var(--ink-3)" : undefined,
        outlineOffset: "-2px",
        opacity: f === "quiet" ? 0.92 : 1,
        color: "var(--ink)",
        borderRadius: 8,
        border: "none",
        borderLeftWidth: 3,
        borderLeftStyle: "solid" as const,
        padding: "2px 6px",
      },
    };
  }, [deadlineHours, fullness]);

  // How full each instructor's day is, for the column headers. Derived from the
  // events already in hand — the point of a column is that it reads as one
  // person's day rather than as an anonymous grid, and a name on its own does
  // not do that.
  const loadByResource = useMemo(() => {
    const m = new Map<string, { classes: number; booked: number; seats: number }>();
    for (const e of wallEvents) {
      // Compared as studio-local day keys, never as browser Date days.
      if (view === "day" && studioDateKey(new Date(e.startsAt), timeZone) !== anchor) continue;
      const cur = m.get(e.resourceId) ?? { classes: 0, booked: 0, seats: 0 };
      cur.classes += 1;
      cur.booked += e.bookedCount;
      cur.seats += e.capacity;
      m.set(e.resourceId, cur);
    }
    return m;
  }, [wallEvents, anchor, view, timeZone]);

  const components = useMemo(() => ({
    event: ({ event }: { event: WallEvent }) => {
      const f = fullness(event);
      const unstaffed = event.staffing !== "assigned";
      return (
        <div className="text-[12px] leading-4">
          <div className="flex items-baseline justify-between gap-1.5">
            <span className="min-w-0 truncate font-medium">
              {unstaffed && (
                <span aria-hidden title="Nobody is teaching this">⚠ </span>
              )}
              {event.title}
            </span>
            {/* The number a planner is actually scanning for, so it is the
                biggest thing on the block and set in mono — tabular figures
                line up down a column, which is the whole reason to read one. */}
            <span className="num shrink-0 text-[13px] font-semibold tabular-nums">
              {event.bookedCount}/{event.capacity}
            </span>
          </div>
          <div className="flex items-baseline justify-between gap-1.5 text-ink-2">
            <span className="min-w-0 truncate">
              {unstaffed ? "Nobody assigned" : (event.room ?? "No room")}
              {event.pendingApplications > 0 && (
                <> · <span className="num">{event.pendingApplications}</span> applied</>
              )}
            </span>
            <span className="shrink-0">
              {event.waitlistCount > 0 && (
                <span className="num" title={`${event.waitlistCount} on the waitlist`}>
                  +{event.waitlistCount} wait
                </span>
              )}
              {event.waitlistCount === 0 && f === "full" && <span>Full</span>}
              {event.waitlistCount === 0 && f === "quiet" && !event.flexPending && <span>Quiet</span>}
              {/* A flex slot with nothing else of this instructor's near it.
                  Worth seeing while you are still deciding where to put it:
                  it is a trip for one class that may not run. */}
              {event.standalone && (
                <span style={{ color: "var(--amber-deep)" }} title="Nothing else of this instructor's within 90 minutes">
                  On its own
                </span>
              )}
              {event.flexPending && <span title="Runs only if it reaches its minimum">Flex</span>}
            </span>
          </div>
        </div>
      );
    },
    // One person's day, summarised at the top of their own column.
    resourceHeader: ({ label, resource }: { label: React.ReactNode; resource: Resource }) => {
      const l = loadByResource.get(resource.resourceId);
      const open = resource.resourceId === UNASSIGNED;
      return (
        <div className="px-1 py-1 leading-4">
          <div className={`text-[12.5px] font-medium ${open ? "text-ink" : "text-ink"}`}>
            {open ? "Nobody assigned" : label}
          </div>
          <div className="text-[11px] text-ink-3">
            {!l ? (open ? "Nothing open" : "Free all day")
               : <>
                   <span className="num">{l.classes}</span>
                   {l.classes === 1 ? " class" : " classes"}
                   {l.seats > 0 && <> · <span className="num">{l.booked}/{l.seats}</span></>}
                 </>}
          </div>
        </div>
      );
    },
  }), [fullness, loadByResource]);

  // CLICKING AN EMPTY SLOT CREATES A CLASS THERE.
  //
  // react-big-calendar hands back WALL time, because that is all it has — see
  // lib/tz.ts. It is converted back to a real instant here, once, before it goes
  // anywhere near the database, exactly as a drag already is.
  const [slot, setSlot] = useState<SlotDraft | null>(null);
  const onSelectSlot = useCallback(
    ({ start, end, resourceId }: { start: Date; end: Date; resourceId?: string | number }) => {
      if (view !== "day") return;          // resources only exist on Day
      if (!classTypes.length) return;      // nothing to create; the page says so
      const startsAt = fromStudioWall(new Date(start), timeZone);
      let endsAt = fromStudioWall(new Date(end), timeZone);
      // A single click gives a zero- or one-slot range. Fall back to the first
      // class type's own length rather than inventing a number.
      if (endsAt.getTime() - startsAt.getTime() < 5 * 60_000) {
        endsAt = new Date(startsAt.getTime() + (classTypes[0]?.duration_minutes ?? 50) * 60_000);
      }
      const id = resourceId === undefined ? null : String(resourceId);
      const instructorId = !id || id === UNASSIGNED ? null : id;
      setSlot({
        startsAt: startsAt.toISOString(),
        endsAt: endsAt.toISOString(),
        instructorId,
        instructorName: instructorId
          ? resources.find((r) => r.resourceId === instructorId)?.resourceTitle ?? null
          : null,
        when: new Intl.DateTimeFormat("en-GB", {
          weekday: "long", day: "numeric", month: "long",
          hour: "2-digit", minute: "2-digit", hour12: false, timeZone,
        }).format(startsAt),
        minutes: Math.round((endsAt.getTime() - startsAt.getTime()) / 60_000),
      });
    },
    [view, classTypes, resources, timeZone],
  );

  // WHEN THE GRID IS WIDER THAN THE PANE, SAY SO.
  //
  // The columns keep a readable floor and the view scrolls, which is right — but
  // a grid cut mid-column at the right edge with only a scrollbar underneath
  // reads as "this studio has four instructors and a blank one". The fade and
  // the count are the two things that turn a cut edge into an obvious "there is
  // more this way".
  const wrapRef = useRef<HTMLDivElement | null>(null);
  const [edge, setEdge] = useState<{ left: boolean; right: boolean }>({ left: false, right: false });
  useEffect(() => {
    const scroller = wrapRef.current?.querySelector<HTMLElement>(".rbc-time-view");
    if (!scroller) return;
    const read = () => {
      const max = scroller.scrollWidth - scroller.clientWidth;
      setEdge({ left: scroller.scrollLeft > 2, right: scroller.scrollLeft < max - 2 });
    };
    read();
    scroller.addEventListener("scroll", read, { passive: true });
    // The pane resizes with the rail drawer and the window; a fade that only
    // measured once would sit there after the reason for it had gone.
    const ro = new ResizeObserver(read);
    ro.observe(scroller);
    return () => { scroller.removeEventListener("scroll", read); ro.disconnect(); };
  }, [resources, events, view]);

  return (
    <div>
      {slot && (
        <CreateOnSlot
          draft={slot}
          classTypes={classTypes}
          rooms={rooms}
          onCancel={() => setSlot(null)}
          onDone={() => { setSlot(null); startTransition(() => router.refresh()); }}
        />
      )}
      {notice && (
        <p className="mb-3 border-l-[3px] px-3 py-2 text-[13px] leading-[18px] text-ink"
           style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}
           role="alert">
          {notice}
          {/* Naming what is in the way, and offering to go there. "Conflict
              detected" tells somebody holding a mouse nothing they can act on. */}
          {blockedBy && (
            <>
              {" "}
              <a href={`/roster/${blockedBy.occurrenceId}`}
                 className="font-medium underline underline-offset-4">
                {blockedBy.who ? `${blockedBy.who} is teaching ` : ""}
                {blockedBy.name} at {blockedBy.at}
                {blockedBy.room ? ` in ${blockedBy.room}` : ""}
              </a>.
            </>
          )}
        </p>
      )}
      {/* The previous day's grid stays exactly where it is underneath. A day
          with classes must never render as an empty grid while its data is in
          flight — that confusion cost three rounds on this screen already. */}
      <div style={{ height: "72vh", position: "relative" }}
           aria-busy={isPending}>
        {isPending && (
          <div className="pointer-events-none absolute inset-0 z-10 flex items-start justify-center pt-3"
               role="status">
            <span className="rounded-full px-3 py-1 text-[12px] leading-4 text-ink"
                  style={{ background: "var(--surface)", boxShadow: "0 1px 6px rgba(0,0,0,.12)" }}>
              Loading…
            </span>
          </div>
        )}
        <div ref={wrapRef} className="relative"
             style={{ height: "100%", opacity: isPending ? 0.45 : 1,
                      transition: "opacity 120ms ease" }}>
        {/* Painted OVER the grid's own edge, inside the rounded corner, and
            never over the time gutter on the left. pointer-events none so it
            cannot swallow a drag. */}
        {edge.right && (
          <>
            <div aria-hidden className="pointer-events-none absolute inset-y-0 right-0 z-10 w-12"
                 style={{ background: "linear-gradient(to right, transparent, var(--surface))",
                          borderTopRightRadius: 14, borderBottomRightRadius: 14 }} />
            {/* Vertically centred on the right edge, not at the top: at the top
                it sat level with the Day/Week toggle and read as part of the
                toolbar. Here it is unmistakably attached to the grid's edge. */}
            <div className="pointer-events-none absolute right-2 top-1/2 z-20 -translate-y-1/2
                            rounded-full px-2.5 py-1 text-[11.5px] leading-4 text-ink"
                 style={{ background: "var(--surface)", boxShadow: "0 1px 8px rgba(0,0,0,.18)" }}>
              more <span aria-hidden>→</span>
            </div>
          </>
        )}
        {edge.left && (
          <div aria-hidden className="pointer-events-none absolute inset-y-0 left-14 z-10 w-10"
               style={{ background: "linear-gradient(to left, transparent, var(--surface))" }} />
        )}
        <DnDCalendar
          localizer={localizer}
          formats={formats}
          events={wallEvents}
          // The grid is TOLD which day it is on; it does not decide. Both come
          // from the URL, which is also what the range was fetched for.
          date={wallAt(anchor, 12)}
          onNavigate={(d: Date) => {
            const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`
              + `-${String(d.getDate()).padStart(2, "0")}`;
            go(key, view);
          }}
          view={view === "week" ? Views.WEEK : Views.DAY}
          onView={(v: View) => go(anchor, v === Views.WEEK ? "week" : "day")}
          views={[Views.DAY, Views.WEEK]}
          step={15}
          timeslots={4}
          // A studio does not run at 3am, and twenty-four rows of empty night
          // is most of what the first render showed. Bounded to the working
          // day, and opened on the morning rather than on midnight.
          // From what is actually on the schedule, in studio time. 06:00-22:00
          // was a guess about somebody else's studio, and it hid every class
          // outside it — including, for a Manila studio rendered in a European
          // browser, all of them.
          min={wallAt(anchor, minHour)}
          max={wallAt(anchor, maxHour)}
          scrollToTime={wallAt(anchor, minHour)}
          // Resources only make sense in a day view; a week already spends its
          // horizontal axis on days, so the instructor columns come back on Day.
          resources={view === "day" ? resources : undefined}
          resourceIdAccessor="resourceId"
          resourceTitleAccessor="resourceTitle"
          onEventDrop={onDrop}
          onEventResize={onResize}
          resizable
          selectable={view === "day" && classTypes.length > 0}
          onSelectSlot={onSelectSlot}
          eventPropGetter={eventPropGetter}
          components={components}
          onSelectEvent={openRoster}
          tooltipAccessor={(e: WallEvent) =>
            `${e.title} — ${e.room ?? "no room"} — ${e.bookedCount}/${e.capacity} booked`
            + (e.waitlistCount > 0 ? ` — ${e.waitlistCount} waiting` : "")
            + (e.staffing !== "assigned" ? " — nobody assigned" : "")
            + (e.flexPending ? " — flex, undecided" : "")
            + " — click to open the roster"}
        />
        </div>
      </div>
      <p className="mt-3 text-[12px] leading-4 text-ink-3">
        Times shown in {timeZone}. Click a class to open its roster. Drag to move
        one between times or instructors; drag its edge to change how long it
        runs. A ring means full, a plain block means quiet with the class close
        enough to do something about, amber means nobody is teaching it, and a
        dashed edge means a flex class still waiting on its deadline.
      </p>
    </div>
  );
}
