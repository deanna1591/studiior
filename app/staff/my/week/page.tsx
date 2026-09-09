import { staffScreen } from "@/lib/screen";
import { AppShell, Empty, NavLink } from "@/components/ui";
import WeekPanel, { type WeekClass } from "./panel";

export const dynamic = "force-dynamic";

/**
 * The instructor's own week.
 *
 * Reachable by a manager too, with ?i=<instructor id>, because somebody who
 * says yes at the desk should not have to open the app for it to be recorded —
 * confirm_week() allows the studio on their behalf, and the screen would be
 * lying if it did not.
 */
export default async function MyWeek({
  searchParams,
}: { searchParams: { w?: string; i?: string } }) {
  const screen = await staffScreen("/my/week");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  const { data: mine } = await supabase
    .from("instructors").select("id, display_name")
    .eq("status", "active")
    .eq(searchParams.i ? "id" : "staff_id", searchParams.i ?? ctx.staffId)
    .maybeSingle();

  if (!mine) {
    return (
      <AppShell {...shell} title="My week">
        <Empty>
          There is no instructor record attached to this login, so there is no
          week to confirm. A studio manager can link one from Instructors.
        </Empty>
      </AppShell>
    );
  }

  const { data } = await supabase.rpc("instructor_week", {
    p_instructor_id: mine.id,
    p_week_start: searchParams.w ?? undefined,
  });
  const week = data as unknown as {
    week_start: string; week_end: string; classes: WeekClass[];
  } | null;

  if (!week) {
    return <AppShell {...shell} title="My week"><Empty>Nothing to show.</Empty></AppShell>;
  }

  // Formatted on the SERVER. A formatter crossing into a client component is a
  // runtime error TypeScript does not warn about — the availability screen's
  // lesson, paid for once already.
  const label = new Intl.DateTimeFormat("en-GB", {
    day: "numeric", month: "long", timeZone: ctx.timeZone,
  }).format(new Date(`${week.week_start}T12:00:00Z`));

  const prev = new Date(`${week.week_start}T12:00:00Z`);
  prev.setUTCDate(prev.getUTCDate() - 7);
  const next = new Date(`${week.week_start}T12:00:00Z`);
  next.setUTCDate(next.getUTCDate() + 7);
  const iso = (d: Date) => d.toISOString().slice(0, 10);
  const q = (w: string) => `/my/week?w=${w}${searchParams.i ? `&i=${searchParams.i}` : ""}`;

  return (
    <AppShell
      {...shell}
      title={searchParams.i ? `${mine.display_name}'s week` : "My week"}
      actions={
        <span className="flex items-center gap-3">
          <NavLink href={q(iso(prev))}>Previous</NavLink>
          <NavLink href={q(iso(next))}>Next</NavLink>
        </span>
      }
    >
      <WeekPanel
        instructorId={mine.id}
        weekStart={week.week_start}
        weekLabel={label}
        classes={week.classes ?? []}
      />
    </AppShell>
  );
}
