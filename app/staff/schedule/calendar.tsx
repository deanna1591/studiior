"use client";

import { useCallback, useEffect, useMemo, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Calendar, Views, dateFnsLocalizer, type View } from "react-big-calendar";
import withDragAndDrop from "react-big-calendar/lib/addons/dragAndDrop";
import { format, parse, startOfWeek, getDay } from "date-fns";
import { enGB } from "date-fns/locale";
import { moveClass } from "./actions";
import CreateOnSlot, { type SlotDraft } from "./create-slot";
import BlockPanel, { type BlockFacts } from "@/components/schedule/block-panel";
import type { FreeFirstCardState } from "@/components/schedule/free-first";
import { showsTrialsMarker } from "@/lib/free-first-view";
import { TierMark } from "@/components/tier-mark";

/** Up to two initials, for the month chip where a full name will not fit. */
function initialsOf(full: string): string {
  return full.trim().split(/\s+/).filter(Boolean).slice(0, 2)
    .map((w) => w[0]?.toUpperCase() ?? "").join("") || "?";
}
/** "Nikko Fictitious" -> "Nikko" — the week block names who is teaching first,
 *  then the class, so a column of the same format reads by instructor. */
function firstNameOf(full: string): string {
  return full.trim().split(/\s+/).filter(Boolean)[0] ?? full;
}
import { toStudioWall, fromStudioWall, wallAt, shiftDateKey, studioDateKey } from "@/lib/tz";
import { fmtTime, fmtClock } from "@/lib/time";
import { resolveDrag } from "@/lib/drag-safety";
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

// Decision 55: the studio's clock format. react-big-calendar's own default is
// the locale's; the studio chooses 24h ("13:00") or 12h ("1:00 PM"). Dates and
// day headers are unchanged — only the clock pattern switches.
function makeFormats(timeFormat: "24h" | "12h") {
  const t = timeFormat === "12h" ? "h:mm a" : "HH:mm";
  return {
    timeGutterFormat: t,
    eventTimeRangeFormat: ({ start, end }: { start: Date; end: Date }) =>
      `${format(start, t)}–${format(end, t)}`,
    selectRangeFormat: ({ start, end }: { start: Date; end: Date }) =>
      `${format(start, t)}–${format(end, t)}`,
    dayRangeHeaderFormat: ({ start, end }: { start: Date; end: Date }) =>
      `${format(start, "d MMM")} – ${format(end, "d MMM yyyy")}`,
    dayHeaderFormat: "EEEE d MMMM yyyy",
  };
}

/** The left-hand column. A sentinel rather than null: a resource needs an id. */
export const UNASSIGNED = "unassigned";

/** Minutes per calendar slot — the grid's `step`, and "one full slot" for the
 *  Day-view drag snap (a column change that moves less than this keeps its
 *  time, so a vertical slip between columns never retimes a class). */
const STEP_MIN = 15;

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
  /** Decision 22: a flex class that has been committed to run (e.g. via "Run
   *  anyway"). Draws a small "Runs" badge so staff see which were pushed through. */
  flexCommitted?: boolean;
  tier: string | null;
  effectiveTier?: string | null;
  minimum?: number | null;
  standalone: boolean;
  /** A flex class the cutoff turned off — a DECIDED state, not the dashed
   *  "still waiting on its deadline". Kept apart on purpose. */
  notRunning?: boolean;
  /** Decision 47: a staff cancellation (no_instructor/studio_fault/force_majeure).
   *  Kept visible, drawn cancelled, read-only in the panel. */
  cancelled?: boolean;
  cancellationCause?: string | null;
  /** Decision 38: the assigned instructor confirmed / was asked and has not. */
  assignmentConfirmed?: boolean;
  assignmentAwaiting?: boolean;
  /** Decision 30 amendment (b) follow-up: the per-class free-first state, for the
   *  popup card and the "Trials" marker. Null when the studio does not use it. */
  freeFirst?: FreeFirstCardState | null;
};

/** A CalEvent with the two Dates the grid lays out, in studio wall time. */
type WallEvent = CalEvent & { start: Date; end: Date };

export default function ScheduleCalendar({
  events: initial, resources, classTypes, rooms, timeZone, deadlineHours,
  quietPct, quietWindowDays, fullPct, showTier, coreEnabled, flexEnabled,
  assignmentConfirmations, freeFirstEnabled = false,
  anchor, today, view, minHour, maxHour, weekStartsOn,
  instructorNames, instructorAvatars, canManage, instructorParam, timeFormat = "24h",
}: {
  events: CalEvent[];
  resources: Resource[];
  /** id -> display name for EVERY active instructor, so the block panel and the
   *  week/month blocks can name whoever teaches a class even when their column
   *  is hidden. */
  instructorNames: Record<string, string>;
  /** id -> public avatar URL (or null) for every active instructor. Instructor
   *  photos are public (studio-published), so no signing — passed straight. */
  instructorAvatars: Record<string, string | null>;
  /** Manager-up — whether the Assign controls in the block panel are offered. */
  canManage: boolean;
  /** The active instructor filter ("" all, an id, or "unassigned"), carried
   *  through every navigation so it survives Back/Next and the view toggle. */
  instructorParam: string;
  /** For the slot-click form. Empty means the studio has none yet. */
  classTypes: { id: string; name: string; duration_minutes: number; default_capacity: number }[];
  rooms: { id: string; name: string; capacity: number }[];
  /** Decision 55: the studio's clock format for the gutter and event times. */
  timeFormat?: "24h" | "12h";
  /** The two guarantee switches, for the create form's tier control. */
  coreEnabled: boolean;
  flexEnabled: boolean;
  /** Decision 38 amendment: show the "already confirmed" bypass tick on create. */
  assignmentConfirmations: boolean;
  /** Decision 30 amendment (b) follow-up: the studio uses free first classes, so
   *  the popup shows the "Open to first-timers" card and blocks can show "Trials". */
  freeFirstEnabled?: boolean;
  timeZone: string;
  deadlineHours: number;
  /**
   * Decision 22's two switches, OR'd — the same condition as the tier control on
   * /settings. Reform Collective runs flex on and guarantees off, so an AND
   * would hide the mark on the one studio that has a mixed timetable to read.
   */
  showTier: boolean;
  /** §11's own thresholds, passed in so the calendar and the brief agree. */
  quietPct: number;
  quietWindowDays: number;
  fullPct: number;
  /** The studio-local day being shown, and the studio's own today. */
  anchor: string;
  today: string;
  view: "day" | "week" | "month";
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
  const formats = useMemo(() => makeFormats(timeFormat), [timeFormat]);
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
  const go = useCallback((d: string, v: "day" | "week" | "month") => {
    // The instructor filter travels with every navigation, so Back/Next/Today,
    // the view toggle and drilling into a day all keep whoever you filtered to.
    const f = instructorParam ? `&instructor=${encodeURIComponent(instructorParam)}` : "";
    startTransition(() => {
      router.push(`/schedule?d=${d}&view=${v}${f}`);
    });
  }, [router, instructorParam]);

  // Back and Next are one round trip away, so pay for them before they are
  // pressed. Measured first: server work for a whole day is ~14 ms and a round
  // trip from here is ~58 ms, so the wait is latency and nothing else — which
  // is exactly the kind a prefetch removes and a faster query would not.
  useEffect(() => {
    // Day and week step by a fixed number of days; a month is a variable jump,
    // so it is not prefetched (the adjacent month is a bigger, rarer fetch).
    if (view === "month") return;
    const step = view === "week" ? 7 : 1;
    const f = instructorParam ? `&instructor=${encodeURIComponent(instructorParam)}` : "";
    router.prefetch(`/schedule?d=${shiftDateKey(anchor, -step)}&view=${view}${f}`);
    router.prefetch(`/schedule?d=${shiftDateKey(anchor, step)}&view=${view}${f}`);
  }, [router, anchor, view, instructorParam]);

  // THE ONE PLACE THE ZONE IS APPLIED. react-big-calendar lays out Dates by
  // their browser-local fields, so it is handed Dates whose local fields have
  // been set to the studio's wall clock. Nothing below this line is a real
  // instant; `apply()` converts back before anything is saved.
  const wallEvents: WallEvent[] = useMemo(() => events.map((e) => ({
    ...e,
    start: toStudioWall(new Date(e.startsAt), timeZone),
    end: toStudioWall(new Date(e.endsAt), timeZone),
  })), [events, timeZone]);

  // Clicking a block opens a panel OVER the calendar — the Assign control
  // inline, so a gap can be filled without leaving the week. The full roster is
  // one link away inside it. A drag does not fire this — react-big-calendar's
  // DnD addon separates the two.
  const [selected, setSelected] = useState<CalEvent | null>(null);
  const openPanel = useCallback((e: CalEvent) => { setSelected(e); }, []);

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

      // DRAG SAFETY (Decision 42a amendment c). The strays on hosted came from a
      // Day-view drag that moved a class to another instructor's COLUMN and, by
      // a vertical slip, also changed its TIME — then the nightly top-up refilled
      // the vacated slot. Two guards, on the initial (unconfirmed) call only:
      //
      //  (a) Day view snaps a column change back to the original time unless the
      //      vertical movement exceeds one full slot (STEP minutes), so a slip
      //      between columns never retimes a class.
      //  (b) A drag that DOES change the time asks first, naming the change and
      //      who it emails — a time change is never silent. An instructor-only
      //      change (same time) keeps today's behaviour.
      if (!confirm) {
        const origStart = toStudioWall(new Date(ev.startsAt), timeZone);
        const origEnd = toStudioWall(new Date(ev.endsAt), timeZone);
        const { snapped, timeChanged } = resolveDrag(
          origStart.getTime(), start.getTime(),
          { columnChanged: target !== ev.resourceId, isDay: view === "day", stepMin: STEP_MIN });
        if (snapped) { start = origStart; end = origEnd; }  // a sub-slot slip: keep the time
        if (timeChanged) {
          const fmtT = (d: Date) =>
            fmtClock(d.getHours() * 60 + d.getMinutes(), timeZone, timeFormat);
          const dateLabel = new Intl.DateTimeFormat("en-GB", {
            weekday: "long", day: "numeric", month: "long", timeZone,
          }).format(fromStudioWall(start, timeZone));
          const n = ev.bookedCount;
          const bookedLine = n > 0
            ? `\n\n${n} member${n === 1 ? " is" : "s are"} booked and will be emailed.`
            : "\n\nNo members are booked.";
          const ok = window.confirm(
            `Move ${ev.title} from ${fmtT(origStart)} to ${fmtT(start)} on ${dateLabel}?` + bookedLine);
          if (!ok) { setEvents(before); return; }
          // Proceed confirmed, so move_occurrence emails without a second prompt.
          return apply(ev, start, end, target, true);
        }
      }

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
        if (res.warnings.includes("outside_hours")) {
          // Decision 44: a warning on a drag, like the create paths.
          bits.push("that is outside the studio's opening hours");
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
    [events, timeZone, view],
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
    // A not-running flex slot is a decided cancellation: muted, with a
    // line-through in the content, and NOT dashed (dashed means "flex, still
    // deciding"). The ink stays full strength — muting the tint, not the text,
    // is the lesson from the ended-series block.
    if (e.notRunning || e.cancelled) {
      return {
        style: {
          background: "color-mix(in srgb, var(--ink-3) 8%, var(--surface))",
          borderLeft: "3px solid var(--ink-3)",
        },
      };
    }
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
        // NO OPACITY. It was 0.92 on a quiet block, which composites the label
        // as well as the fill — this project has had to undo opacity on text
        // twice for exactly that, and it was buying nothing here: quiet is
        // already carried by the plain surface, the grey left border and the
        // word "Quiet". Removing it makes the measurement honest rather than
        // approximately right.
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
      const isWeek = view === "week";
      // The block renders its own time (the rbc event label is dropped in CSS),
      // so a 50-minute block is exactly two lines and never clips. Studio clock
      // per Decision 55: event.start/end are wall Dates (local fields ARE the
      // studio clock), so date-fns format reads the studio's hour directly.
      const clockFmt = timeFormat === "12h" ? "h:mm a" : "HH:mm";
      const timeRange = `${format(event.start, clockFmt)}–${format(event.end, clockFmt)}`;
      const headcount = `${event.bookedCount}/${event.capacity}`;
      // Shared frame: two stacked lines filling the block height.
      const root = `sched-block ${isWeek ? "wk-block" : ""} flex h-full flex-col justify-center gap-px text-[12px] leading-[15px]`;

      // A struck, muted two-line block for the two decided-off states. Staffing
      // colour and the line-through carry the state; line 1 keeps time+headcount
      // so the slot still reads at a glance.
      if (event.cancelled || event.notRunning) {
        const reason = event.cancelled
          ? (event.cancellationCause === "no_instructor" ? "cancelled, no instructor"
             : event.cancellationCause === "force_majeure" ? "cancelled, beyond anyone's control"
             : "cancelled, studio's reason")
          : (event.bookedCount === 0 ? "not running, nobody booked"
             : (event.minimum ?? 0) > 0 ? `not running, ${event.bookedCount} booked, needed ${event.minimum}`
             : `not running, ${event.bookedCount} booked`);
        return (
          <div className={root}>
            <div className="flex items-baseline gap-1.5">
              <span className="num min-w-0 flex-1 truncate tabular-nums text-ink-2">{timeRange}</span>
              {(event.cancelled ? event.bookedCount > 0 : true) && (
                <span className="num shrink-0 font-semibold tabular-nums text-ink-2">{headcount}</span>
              )}
            </div>
            <div className="min-w-0 truncate text-ink-2">
              <span className="font-medium text-ink line-through">{event.title}</span>
              {" — "}{reason}
            </div>
          </div>
        );
      }

      // THE "TRIALS" MARKER (Decision 30 amendment b): open to first-timers BY
      // OVERRIDE only — a rules-open core class would mark every block. A small
      // pill, --ink on --accent-chip with a 1px border, radius full, sitting on
      // the RIGHT of line 2 directly under the headcount above it (never centred,
      // never free-floating). In WEEK view a column too narrow for the pill
      // swaps it for a 6px dot (container query on .wk-block).
      const trialsPill = (
        <span className="shrink-0 rounded-full border px-1 text-[10.5px] font-medium leading-[14px]"
              style={{ background: "var(--accent-chip)", color: "var(--ink)", borderColor: "var(--line-2)" }}
              title="Open to first-timers (set for this class)">Trials</span>
      );
      const trials = !showsTrialsMarker(event.freeFirst) ? null : isWeek ? (
        <span className="shrink-0 leading-none">
          <span className="wk-trials">{trialsPill}</span>
          <span aria-hidden className="wk-trials-dot rounded-full align-middle"
                style={{ width: 6, height: 6, background: "var(--accent-chip)", border: "1px solid var(--line-2)" }}
                title="Open to first-timers" />
        </span>
      ) : trialsPill;

      const unstaffed = event.staffing !== "assigned";
      // The tier dot (● core · ○ flex · ◆ always) — SHAPE not colour, since
      // colour already carries staffing. Shared by both views' line 2.
      const tierDot = showTier && event.tier ? (
        <>
          <TierMark tier={event.tier as "core" | "flex" | "always"}
                    effective={event.effectiveTier as "core" | "flex" | "always" | null}
                    minimum={event.minimum ?? null} />
          <span className="sr-only">
            {event.tier === "flex" ? "Flex class. "
             : event.tier === "always" ? "Always runs. " : "Core class. "}
          </span>
        </>
      ) : null;

      // THE NORMAL BLOCK: exactly two lines, and both carry what the old third
      // line did — nothing moves to a third row that a 50-minute block would clip.
      //   line 1: time range (left) · headcount (right), mono + tabular.
      //   line 2 (WEEK): tier dot + instructor first name · class name, the class
      //     name truncating first; below 104px the class name drops (container
      //     query) and the instructor stands alone. Trials pill/dot at the right.
      //   line 2 (DAY): tier dot + class name, then the room and status words
      //     (applied · +N wait · Full · Quiet · On its own · Flex · Runs ·
      //     ✓/awaiting) as one muted run that truncates before the name. Trials
      //     pill at the far right.
      const f = fullness(event);
      let line2;
      if (isWeek) {
        const name = event.resourceId === UNASSIGNED
          ? null : (instructorNames[event.resourceId] ?? null);
        line2 = (
          <div className="flex items-center gap-1.5">
            <span className="flex min-w-0 flex-1 items-center gap-1 text-ink">
              {tierDot}
              <span className="shrink-0 font-medium">
                {unstaffed ? "Unassigned" : firstNameOf(name ?? event.title)}
              </span>
              <span className="wk-cls min-w-0 truncate text-ink-2">· {event.title}</span>
            </span>
            {trials}
          </div>
        );
      } else {
        // The muted room + status run, interleaved with " · ". Room first, then
        // whichever states apply — the same set the old third line carried.
        const bits: React.ReactNode[] = [];
        bits.push(unstaffed ? "Nobody assigned" : (event.room ?? "No room"));
        if (event.pendingApplications > 0)
          bits.push(<span key="app"><span className="num">{event.pendingApplications}</span> applied</span>);
        if (event.waitlistCount > 0)
          bits.push(<span key="wait" className="num" title={`${event.waitlistCount} on the waitlist`}>+{event.waitlistCount} wait</span>);
        if (event.waitlistCount === 0 && f === "full") bits.push("Full");
        if (event.waitlistCount === 0 && f === "quiet" && !event.flexPending) bits.push("Quiet");
        if (event.standalone)
          bits.push(<span key="alone" title="Nothing else of this instructor's within 90 minutes">On its own</span>);
        if (event.flexPending)
          bits.push(<span key="flex" title="Runs only if it reaches its minimum">Flex{event.minimum ? <> · <span className="num">{event.minimum}</span>+</> : null}</span>);
        if (event.flexCommitted)
          bits.push(<span key="runs" title="Committed to run, even below its minimum">Runs</span>);
        if (assignmentConfirmations && event.assignmentConfirmed)
          bits.push(<span key="ok" title="The instructor confirmed">✓</span>);
        if (assignmentConfirmations && event.assignmentAwaiting)
          bits.push(<span key="aw" title="Awaiting the instructor's confirmation">awaiting</span>);
        line2 = (
          <div className="flex items-center gap-1.5">
            {/* Name holds its width (capped at 70%, truncating only as a last
                resort) so the muted status run is what gives way first. */}
            <span className="flex min-w-0 max-w-[70%] shrink-0 items-center gap-1 font-medium text-ink">
              {tierDot}
              <span className="min-w-0 truncate">{event.title}</span>
            </span>
            <span className="min-w-0 flex-1 truncate text-ink-2">
              {bits.map((b, i) => <span key={i}>{i > 0 ? " · " : null}{b}</span>)}
            </span>
            {trials}
          </div>
        );
      }

      return (
        <div className={root}>
          <div className="flex items-baseline gap-1.5">
            <span className="num min-w-0 flex-1 truncate tabular-nums text-ink">{timeRange}</span>
            <span className="num shrink-0 text-[13px] font-semibold tabular-nums text-ink">{headcount}</span>
          </div>
          {line2}
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
    // MONTH: a chip per class in a day cell — no time-positioned blocks, which
    // at real scale are unreadable. Time, class, who (initials) or a gap marker,
    // and the fill. Unstaffed reads as unstaffed at a glance: the amber fill
    // (eventPropGetter) plus the marker, which is the main reason to open a month.
    month: {
      event: ({ event }: { event: WallEvent }) => {
        const unstaffed = event.staffing !== "assigned";
        const name = event.resourceId === UNASSIGNED
          ? null : (instructorNames[event.resourceId] ?? null);
        return (
          <span className="flex items-center gap-1 text-[11px] leading-4">
            {showTier && event.tier && (
              <TierMark tier={event.tier as "core" | "flex" | "always"}
                        effective={event.effectiveTier as "core" | "flex" | "always" | null}
                        minimum={event.minimum ?? null} />
            )}
            <span className="num shrink-0">{format(event.start, "HH:mm")}</span>
            <span className="min-w-0 flex-1 truncate">{event.title}</span>
            {unstaffed
              ? <span aria-hidden title="Nobody is teaching this" className="shrink-0">⚠</span>
              : <span className="num shrink-0" title={name ?? undefined}>{name ? initialsOf(name) : "—"}</span>}
            <span className="num shrink-0 font-semibold tabular-nums">
              {event.bookedCount}/{event.capacity}
            </span>
          </span>
        );
      },
    },
  }), [fullness, loadByResource, view, showTier, instructorNames, instructorAvatars, timeFormat]);

  // CLICKING AN EMPTY SLOT CREATES A CLASS THERE.
  //
  // react-big-calendar hands back WALL time, because that is all it has — see
  // lib/tz.ts. It is converted back to a real instant here, once, before it goes
  // anywhere near the database, exactly as a drag already is.
  const [slot, setSlot] = useState<SlotDraft | null>(null);
  const onSelectSlot = useCallback(
    ({ start, end, resourceId }: { start: Date; end: Date; resourceId?: string | number }) => {
      // Decision 37: create from a slot on ANY view. react-big-calendar hands
      // WALL Dates (their local fields ARE the studio clock — see lib/tz), so
      // the date, time and weekday come straight off those fields; the form does
      // the wall -> instant conversion, once, exactly as a drag does.
      if (!classTypes.length) return;      // nothing to create; the page says so
      const p = (n: number) => String(n).padStart(2, "0");
      const wall = new Date(start);
      const dateKey = `${wall.getFullYear()}-${p(wall.getMonth() + 1)}-${p(wall.getDate())}`;
      const timeHHMM = `${p(wall.getHours())}:${p(wall.getMinutes())}`;
      const slotLen = Math.round((new Date(end).getTime() - wall.getTime()) / 60_000);
      // Day columns are instructors; Week/Month have none, so the form asks.
      const id = view === "day" && resourceId !== undefined ? String(resourceId) : null;
      const instructorId = !id || id === UNASSIGNED ? null : id;
      setSlot({
        view,
        dateKey,
        // Month cells carry no time (a day, not an instant), so the form asks
        // for one; Day/Week carry the clicked time.
        timeHHMM: view === "month" ? null : timeHHMM,
        weekday: wall.getDay(),
        slotMinutes: view !== "month" && slotLen >= 5 ? slotLen : null,
        instructorId,
        instructorName: instructorId
          ? resources.find((r) => r.resourceId === instructorId)?.resourceTitle ?? null
          : null,
      });
    },
    [view, classTypes, resources],
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
          // Every active instructor, so Week/Month (which have no columns) can
          // still choose one; instructorNames is the id->name map for all.
          instructors={Object.entries(instructorNames).map(([id, name]) => ({ id, name }))}
          coreEnabled={coreEnabled}
          flexEnabled={flexEnabled}
          assignmentConfirmations={assignmentConfirmations}
          timeZone={timeZone}
          onCancel={() => setSlot(null)}
          onDone={() => { setSlot(null); startTransition(() => router.refresh()); }}
        />
      )}
      {selected && (
        <BlockPanel
          canManage={canManage}
          confirmationsOn={assignmentConfirmations}
          freeFirstEnabled={freeFirstEnabled}
          rosterHref={`/roster/${selected.id}`}
          facts={{
            id: selected.id,
            freeFirst: selected.freeFirst ?? null,
            title: selected.title,
            when: new Intl.DateTimeFormat("en-GB", {
              weekday: "long", day: "numeric", month: "long", timeZone,
            }).format(new Date(selected.startsAt)) + " "
              + fmtTime(selected.startsAt, timeZone, timeFormat),
            weekday: new Intl.DateTimeFormat("en-GB", { weekday: "long", timeZone })
              .format(new Date(selected.startsAt)),
            cancelled: selected.cancelled ?? false,
            cancellationCause: selected.cancellationCause ?? null,
            instructorId: selected.resourceId === UNASSIGNED ? null : selected.resourceId,
            instructorName: selected.resourceId === UNASSIGNED
              ? null : instructorNames[selected.resourceId] ?? null,
            bookedCount: selected.bookedCount,
            capacity: selected.capacity,
            waitlistCount: selected.waitlistCount,
            staffing: selected.staffing,
            pendingApplications: selected.pendingApplications,
          }}
          onClose={() => setSelected(null)}
          onAssigned={(instructorId) => {
            // Instant feedback: the class becomes assigned in place — whether it
            // was unstaffed (assign) or already had someone (a swap). The action
            // also revalidates /schedule, so the server's own fresh events land
            // right after and agree.
            setEvents((prev) => prev.map((e) =>
              e.id === selected.id
                ? { ...e, resourceId: instructorId, staffing: "assigned" }
                : e));
            setSelected(null);
            startTransition(() => router.refresh());
          }}
          onUnassigned={() => {
            // Opened as a shift: nobody on it, back in the Unassigned column.
            setEvents((prev) => prev.map((e) =>
              e.id === selected.id
                ? { ...e, resourceId: UNASSIGNED, staffing: "open" }
                : e));
            setSelected(null);
            startTransition(() => router.refresh());
          }}
          onFreeFirstChange={(s) => {
            // The popup stays open; the block behind it gets the "Trials" marker
            // at once, and the server's fresh events land right after.
            setEvents((prev) => prev.map((e) => e.id === selected.id ? { ...e, freeFirst: s } : e));
            setSelected((prev) => (prev && prev.id === selected.id ? { ...prev, freeFirst: s } : prev));
            startTransition(() => router.refresh());
          }}
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
        <div ref={wrapRef} className={`relative ${view === "week" ? "sched-week" : ""}`}
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
          view={view === "week" ? Views.WEEK : view === "month" ? Views.MONTH : Views.DAY}
          onView={(v: View) =>
            go(anchor, v === Views.WEEK ? "week" : v === Views.MONTH ? "month" : "day")}
          views={[Views.DAY, Views.WEEK, Views.MONTH]}
          // Month: clicking a day's number drills into that day's view.
          onDrillDown={(d: Date) => {
            const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`
              + `-${String(d.getDate()).padStart(2, "0")}`;
            go(key, "day");
          }}
          step={STEP_MIN}
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
          selectable={classTypes.length > 0}
          onSelectSlot={onSelectSlot}
          eventPropGetter={eventPropGetter}
          components={components}
          onSelectEvent={openPanel}
          tooltipAccessor={(e: WallEvent) =>
            `${e.title} — ${e.room ?? "no room"} — ${e.bookedCount}/${e.capacity} booked`
            + (e.waitlistCount > 0 ? ` — ${e.waitlistCount} waiting` : "")
            + (e.staffing !== "assigned" ? " — nobody assigned" : "")
            + (e.flexPending ? " — flex, undecided" : "")
            + " — click for options"}
        />
        </div>
      </div>
      <p className="mt-3 text-[12px] leading-4 text-ink-3">
        Times shown in {timeZone}. Click a class for its details, to assign an
        unstaffed one, or to open its roster. Drag to move one between times or
        instructors; drag its edge to change how long it runs. A ring means full, a plain block means quiet with the class close
        enough to do something about, amber means nobody is teaching it, and a
        dashed edge means a flex class still waiting on its deadline.
        {showTier ? (
          <>
            {" "}
            <span className="tier-mark">●</span> is a core class and{" "}
            <span className="tier-mark">○</span> a flex one — that is what the class
            IS, and it does not change. The dashed edge is the temporary half: it
            clears the moment a flex class reaches its minimum and commits.
          </>
        ) : null}
      </p>
    </div>
  );
}
