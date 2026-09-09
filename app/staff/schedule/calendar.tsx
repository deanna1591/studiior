"use client";

import { useCallback, useMemo, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Calendar, Views, dateFnsLocalizer, type View } from "react-big-calendar";
import withDragAndDrop from "react-big-calendar/lib/addons/dragAndDrop";
import { format, parse, startOfWeek, getDay } from "date-fns";
import { enGB } from "date-fns/locale";
import { moveClass } from "./actions";
import "react-big-calendar/lib/css/react-big-calendar.css";
import "react-big-calendar/lib/addons/dragAndDrop/styles.css";

const DnDCalendar = withDragAndDrop<CalEvent, Resource>(Calendar as never);

const localizer = dateFnsLocalizer({
  format, parse, startOfWeek, getDay, locales: { "en-GB": enGB },
});

/** The left-hand column. A sentinel rather than null: a resource needs an id. */
export const UNASSIGNED = "unassigned";

/** A wall-clock hour on the day being shown. */
function dayAt(d: Date, hour: number) {
  const x = new Date(d);
  x.setHours(hour, 0, 0, 0);
  return x;
}

export type Resource = { resourceId: string; resourceTitle: string };
export type CalEvent = {
  id: string;
  title: string;
  start: Date;
  end: Date;
  resourceId: string;
  staffing: "assigned" | "open" | "pending_approval";
  bookedCount: number;
  capacity: number;
  waitlistCount: number;
  /** Hours from now until it starts, so "approaching" can be decided here. */
  hoursAway: number;
  room: string | null;
  pendingApplications: number;
};

export default function ScheduleCalendar({
  events: initial, resources, timeZone, deadlineHours,
  quietPct, quietWindowDays, fullPct,
}: {
  events: CalEvent[];
  resources: Resource[];
  timeZone: string;
  deadlineHours: number;
  /** §11's own thresholds, passed in so the calendar and the brief agree. */
  quietPct: number;
  quietWindowDays: number;
  fullPct: number;
}) {
  const [events, setEvents] = useState(initial);
  const [view, setView] = useState<View>(Views.DAY);
  const [date, setDate] = useState(new Date());
  const [notice, setNotice] = useState<string | null>(null);
  const [blockedBy, setBlockedBy] = useState<
    { occurrenceId: string; name: string; at: string; who: string | null; room: string | null } | null
  >(null);
  const [, startTransition] = useTransition();
  const router = useRouter();

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
          e.id === ev.id ? { ...e, start, end, resourceId: target } : e));
      }

      const res = await moveClass({
        occurrenceId: ev.id,
        startsAt: start.toISOString(),
        endsAt: end.toISOString(),
        instructorId: target === UNASSIGNED ? null : target,
        confirm,
      });

      if (res.ok) {
        setEvents(events.map((e) =>
          e.id === ev.id ? { ...e, start, end, resourceId: target } : e));
        const bits: string[] = [];
        if (res.warnings.includes("outside_availability")) {
          // Decision 9: permitted, and said out loud.
          bits.push("that is outside the availability they gave us");
        }
        if (res.significant) {
          bits.push("everyone booked can now cancel without penalty, because the time they agreed to has changed");
        }
        if (bits.length) setNotice(`Moved — ${bits.join(", and ")}.`);
        startTransition(() => {});
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
    [events],
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

  const eventPropGetter = useCallback((e: CalEvent) => {
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
    const key = date.toDateString();
    for (const e of events) {
      if (view === Views.DAY && e.start.toDateString() !== key) continue;
      const cur = m.get(e.resourceId) ?? { classes: 0, booked: 0, seats: 0 };
      cur.classes += 1;
      cur.booked += e.bookedCount;
      cur.seats += e.capacity;
      m.set(e.resourceId, cur);
    }
    return m;
  }, [events, date, view]);

  const components = useMemo(() => ({
    event: ({ event }: { event: CalEvent }) => {
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
              {event.waitlistCount === 0 && f === "quiet" && <span>Quiet</span>}
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

  return (
    <div>
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
      <div style={{ height: "72vh" }}>
        <DnDCalendar
          localizer={localizer}
          events={events}
          date={date}
          onNavigate={setDate}
          view={view}
          onView={setView}
          views={[Views.DAY, Views.WEEK]}
          step={15}
          timeslots={4}
          // A studio does not run at 3am, and twenty-four rows of empty night
          // is most of what the first render showed. Bounded to the working
          // day, and opened on the morning rather than on midnight.
          min={dayAt(date, 6)}
          max={dayAt(date, 22)}
          scrollToTime={dayAt(date, 7)}
          // Resources only make sense in a day view; a week already spends its
          // horizontal axis on days, so the instructor columns come back on Day.
          resources={view === Views.DAY ? resources : undefined}
          resourceIdAccessor="resourceId"
          resourceTitleAccessor="resourceTitle"
          onEventDrop={onDrop}
          onEventResize={onResize}
          resizable
          selectable={false}
          eventPropGetter={eventPropGetter}
          components={components}
          onSelectEvent={openRoster}
          tooltipAccessor={(e: CalEvent) =>
            `${e.title} — ${e.room ?? "no room"} — ${e.bookedCount}/${e.capacity} booked`
            + (e.waitlistCount > 0 ? ` — ${e.waitlistCount} waiting` : "")
            + (e.staffing !== "assigned" ? " — nobody assigned" : "")
            + " — click to open the roster"}
        />
      </div>
      <p className="mt-3 text-[12px] leading-4 text-ink-3">
        Times shown in {timeZone}. Click a class to open its roster. Drag to move
        one between times or instructors; drag its edge to change how long it
        runs. A ring means full, a plain block means quiet with the class close
        enough to do something about, and amber means nobody is teaching it.
      </p>
    </div>
  );
}
