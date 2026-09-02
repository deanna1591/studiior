"use client";

import { useCallback, useMemo, useState, useTransition } from "react";
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
  room: string | null;
  pendingApplications: number;
};

export default function ScheduleCalendar({
  events: initial, resources, timeZone,
}: {
  events: CalEvent[];
  resources: Resource[];
  timeZone: string;
}) {
  const [events, setEvents] = useState(initial);
  const [view, setView] = useState<View>(Views.DAY);
  const [date, setDate] = useState(new Date());
  const [notice, setNotice] = useState<string | null>(null);
  const [, startTransition] = useTransition();

  // Optimistic, and reverted the moment the database says no. The calendar is
  // a view of what move_occurrence() allows, never a second opinion about it.
  const apply = useCallback(
    async (
      ev: CalEvent, start: Date, end: Date, resourceId: string | undefined,
      confirm = false,
    ) => {
      const target = resourceId ?? ev.resourceId;
      const before = events;
      const optimistic = events.map((e) =>
        e.id === ev.id ? { ...e, start, end, resourceId: target } : e);
      setEvents(optimistic);
      setNotice(null);

      const res = await moveClass({
        occurrenceId: ev.id,
        startsAt: start.toISOString(),
        endsAt: end.toISOString(),
        instructorId: target === UNASSIGNED ? null : target,
        confirm,
      });

      if (res.ok) {
        if (res.warnings.includes("outside_availability")) {
          // Decision 9: permitted, and said out loud. The move already happened.
          setNotice("Moved — but that is outside the availability they gave us.");
        }
        startTransition(() => {});
        return;
      }

      if (res.kind === "confirm") {
        const n = res.bookedCount;
        const yes = window.confirm(
          `${n} member${n === 1 ? " is" : "s are"} booked into this class.\n\n` +
          `Moving it will email ${n === 1 ? "them" : "all of them"} to say the time has changed. Go ahead?`,
        );
        if (yes) return apply(ev, start, end, target, true);
      } else {
        setNotice(res.message);
      }
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
  const eventPropGetter = useCallback((e: CalEvent) => {
    const unstaffed = e.staffing !== "assigned";
    const waiting = e.staffing === "pending_approval";
    return {
      style: {
        background: unstaffed ? "var(--amber-tint)" : "var(--lime-tint)",
        borderLeft: `3px solid ${waiting ? "var(--amber-deep)"
                    : unstaffed ? "var(--coral)" : "var(--lime-text)"}`,
        color: "var(--ink)",
        borderRadius: 8,
        border: "none",
        borderLeftWidth: 3,
        borderLeftStyle: "solid" as const,
        padding: "2px 6px",
      },
    };
  }, []);

  const components = useMemo(() => ({
    event: ({ event }: { event: CalEvent }) => (
      <div className="text-[12px] leading-4">
        <div className="font-medium">{event.title}</div>
        <div className="text-ink-2">
          {event.room ?? "No room"} · <span className="num">{event.bookedCount}</span>/
          <span className="num">{event.capacity}</span>
          {event.pendingApplications > 0 && (
            <> · <span className="num">{event.pendingApplications}</span> applied</>
          )}
        </div>
      </div>
    ),
  }), []);

  return (
    <div>
      {notice && (
        <p className="mb-3 border-l-[3px] px-3 py-2 text-[13px] leading-[18px] text-ink"
           style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}
           role="alert">
          {notice}
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
          tooltipAccessor={(e: CalEvent) =>
            `${e.title} — ${e.room ?? "no room"} — ${e.bookedCount}/${e.capacity} booked`}
        />
      </div>
      <p className="mt-3 text-[12px] leading-4 text-ink-3">
        Times shown in {timeZone}. Drag to move a class between times or
        instructors; drag its edge to change how long it runs.
      </p>
    </div>
  );
}
