import { AppShell, Empty, NavLink } from "@/components/ui";
import { staffScreen } from "@/lib/screen";
import ScheduleCalendar, { UNASSIGNED, type CalEvent, type Resource } from "./calendar";

export const dynamic = "force-dynamic";

/**
 * The timetable, as a calendar.
 *
 * One column per instructor plus Unassigned on the left, which is where an open
 * shift lives until somebody takes it. Day is primary because that is the unit
 * a studio runs on; week is there for planning.
 *
 * Owner and manager only — Decision 9 keeps the timetable with them, and
 * Decision 17 does not change that. What Decision 17 adds is that an instructor
 * can ASK, which happens on their own screen, not this one.
 */
export default async function Schedule() {
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

  const from = new Date();
  from.setDate(from.getDate() - 7);
  const to = new Date();
  to.setDate(to.getDate() + 28);

  const [{ data: instructors }, { data: occurrences }, { data: pending }, { data: settings }] =
    await Promise.all([
      supabase.from("instructors")
        .select("id, display_name").eq("status", "active").order("display_name"),
      supabase.from("class_occurrences")
        .select("id, name, starts_at, ends_at, instructor_id, capacity, booked_count, staffing, status, rooms(name)")
        .gte("starts_at", from.toISOString())
        .lt("starts_at", to.toISOString())
        .neq("status", "cancelled")
        .order("starts_at"),
      supabase.from("shift_applications")
        .select("occurrence_id").eq("status", "pending"),
      supabase.from("studio_settings")
        .select("unstaffed_deadline_hours").eq("studio_id", ctx.studioId).maybeSingle(),
    ]);

  const deadlineHours = settings?.unstaffed_deadline_hours ?? 48;

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

  const events: CalEvent[] = (occurrences ?? []).map((o) => ({
    id: o.id,
    title: o.name,
    start: new Date(o.starts_at),
    end: new Date(o.ends_at),
    resourceId: o.instructor_id ?? UNASSIGNED,
    staffing: (o.staffing ?? "assigned") as CalEvent["staffing"],
    bookedCount: o.booked_count,
    capacity: o.capacity,
    room: o.rooms?.name ?? null,
    pendingApplications: appCount.get(o.id) ?? 0,
    hoursAway: (new Date(o.starts_at).getTime() - Date.now()) / 3_600_000,
  }));

  return (
    <AppShell {...shell} title="Schedule"
              actions={
                <>
                  <NavLink href="/shifts/applications">Applications</NavLink>
                  <NavLink href="/classes/new">Add a class</NavLink>
                </>
              }>
      {resources.length === 1 ? (
        <Empty>
          Add an instructor and your timetable will have columns to fill.{" "}
          <NavLink href="/instructors">Add one</NavLink>
        </Empty>
      ) : (
        <ScheduleCalendar events={events} resources={resources}
                          timeZone={ctx.timeZone} deadlineHours={deadlineHours} />
      )}
    </AppShell>
  );
}
