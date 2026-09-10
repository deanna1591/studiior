import { cookies } from "next/headers";
import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { SetupShell, SetupRow, ArchivedSection } from "@/components/setup-list";
import { parseRrule, describeRule } from "@/lib/rrule";
import { studioToday } from "@/lib/tz";
import ViewTabs from "./tabs";
import SeriesGrid, { type GridSeries } from "./grid";

export const dynamic = "force-dynamic";

export default async function SeriesList({
  searchParams,
}: { searchParams: { view?: string } }) {
  const screen = await staffScreen("/series");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return (
      <AppShell {...shell} title="Recurring classes">
        <Denied what="Changing the timetable" role={ctx.role} />
      </AppShell>
    );
  }

  // The tab, from the URL if it was just clicked and from the cookie otherwise,
  // so a returning studio lands on the view it chose rather than on the default.
  const view: "list" | "grid" =
    searchParams.view === "grid" ? "grid"
    : searchParams.view === "list" ? "list"
    : cookies().get("series_view")?.value === "grid" ? "grid" : "list";

  // One request, joined — the grid needs the class type's colour and the room's
  // name, and a second round trip for either would be the chain the schedule
  // page just had taken out of it.
  const [{ data: series }, { data: settings }] = await Promise.all([
    supabase.from("class_series")
      .select("id, name, rrule, time_of_day, duration_minutes, ends_on, status, capacity, instructor_id, class_type_id, class_types(name, color), rooms(name)")
      .order("status").order("time_of_day"),
    supabase.from("studio_settings")
      .select("week_starts_on").eq("studio_id", ctx.studioId).maybeSingle(),
  ]);

  const live = (series ?? []).filter((s) => s.status === "active");
  const gone = (series ?? []).filter((s) => s.status !== "active");

  // Described on the server. describeRule is a pure function on both sides, but
  // the STRING crosses the boundary, never the function.
  const meta = (s: (typeof live)[number]) => {
    const { rule, until, unsupported } = parseRrule(s.rrule);
    if (unsupported) return `Repeat rule Studiior cannot keep (${unsupported})`;
    return describeRule(rule, s.ends_on ?? until, s.time_of_day);
  };

  if (view === "grid") {
    const forGrid: GridSeries[] = live.map((s) => ({
      id: s.id, name: s.name, rrule: s.rrule,
      time_of_day: s.time_of_day, duration_minutes: s.duration_minutes,
      ends_on: s.ends_on,
      room_name: s.rooms?.name ?? null,
      class_type_id: s.class_type_id,
      class_type_name: s.class_types?.name ?? null,
      class_type_color: s.class_types?.color ?? null,
    }));
    return (
      <AppShell {...shell} title="Recurring classes"
                actions={
                  <>
                    <ViewTabs view={view} />
                    <Link href="/series/new"
                          className="inline-flex items-center rounded bg-ink px-3.5 py-2
                                     text-[13px] font-medium leading-[18px] text-paper hover:bg-ink-2">
                      Add a series
                    </Link>
                  </>
                }>
        <p className="mb-5 max-w-[62ch] text-[13px] leading-[20px] text-ink-2">
          Your standing week — what the timetable repeats, not what is happening on
          any particular day. The{" "}
          <Link href="/schedule" className="text-lime-text underline underline-offset-4">
            schedule
          </Link>{" "}
          answers that, with instructors and bookings on it.
        </p>
        <SeriesGrid
          series={forGrid}
          weekStartsOn={settings?.week_starts_on ?? 1}
          today={studioToday(ctx.timeZone)}
        />
      </AppShell>
    );
  }

  return (
    <SetupShell
      shell={shell}
      title="Recurring classes"
      blurb="Your standing timetable. A series materialises twelve months of classes and keeps
             itself topped up every night, so a member can always book a month ahead.
             One-off classes are added from the schedule instead."
      tabs={<ViewTabs view={view} />}
      newHref="/series/new" newLabel="Add a series" count={live.length}
      empty="No recurring classes yet — this is where a studio's week comes from."
      archived={
        <ArchivedSection noun="series" count={gone.length}>
          {gone.map((s) => (
            <SetupRow key={s.id} href={`/series/${s.id}`} name={s.name}
                      meta={meta(s)} archived />
          ))}
        </ArchivedSection>
      }
    >
      {live.map((s) => (
        <SetupRow key={s.id} href={`/series/${s.id}`} name={s.name}
                  meta={meta(s)}
                  right={s.instructor_id ? undefined : "open"} />
      ))}
    </SetupShell>
  );
}
