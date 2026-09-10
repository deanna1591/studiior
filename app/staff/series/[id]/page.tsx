import Link from "next/link";
import { notFound } from "next/navigation";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, NavLink, SectionLabel } from "@/components/ui";
import { parseRrule } from "@/lib/rrule";
import SeriesForm from "../form";
import SeriesLifecycle from "../lifecycle";
import { localDates, seriesOptions } from "../data";
import { studioToday } from "@/lib/tz";

export const dynamic = "force-dynamic";

export default async function EditSeries({ params }: { params: { id: string } }) {
  const screen = await staffScreen(`/series/${params.id}`);
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return (
      <AppShell {...shell} title="Series">
        <Denied what="Changing the timetable" role={ctx.role} />
      </AppShell>
    );
  }

  const { data: s } = await supabase
    .from("class_series")
    .select("id, name, class_type_id, room_id, instructor_id, capacity, duration_minutes, rrule, starts_on, ends_on, time_of_day, description, status")
    .eq("id", params.id).maybeSingle();
  if (!s) notFound();

  const { classTypes, rooms, instructors } = await seriesOptions(supabase);
  const { tomorrow } = localDates(ctx.timeZone);
  const { rule, until, unsupported } = parseRrule(s.rrule);

  // How much of the calendar this series is actually holding, so "twelve months
  // of classes" is a number on the screen rather than a claim in a sentence.
  const [{ count: future }, { count: booked }] = await Promise.all([
    supabase.from("class_occurrences").select("id", { count: "exact", head: true })
      .eq("series_id", s.id).eq("status", "scheduled").gte("starts_at", new Date().toISOString()),
    supabase.from("class_occurrences").select("id", { count: "exact", head: true })
      .eq("series_id", s.id).eq("status", "scheduled").gt("booked_count", 0)
      .gte("starts_at", new Date().toISOString()),
  ]);

  return (
    <AppShell {...shell} title={s.name}
              actions={<NavLink href="/series">Back to recurring classes</NavLink>}>
      <div className="mb-6 max-w-xl rounded border border-line bg-surface px-3.5 py-3">
        <SectionLabel>On the calendar now</SectionLabel>
        <p className="mt-1 text-[13px] leading-[19px] text-ink-2">
          <span className="num text-ink">{future ?? 0}</span> classes still to come,{" "}
          <span className="num text-ink">{booked ?? 0}</span> with people booked.{" "}
          <Link href="/schedule" className="text-lime-text underline underline-offset-4">
            See them on the schedule
          </Link>
          , where one class can be moved on its own without touching the rest.
        </p>
      </div>

      <p className="mb-5 max-w-[54ch] text-[13px] leading-[20px] text-ink-2">
        An edit here changes the classes this series has already put on the calendar, from
        the date you choose forward. It never rewrites the past, and it shows you exactly
        what it will do before it does it. To stop it, archive it or give it an end date
        at the bottom of this page.
      </p>

      <SeriesForm
        mode="edit"
        timeZone={ctx.timeZone}
        tomorrow={tomorrow}
        classTypes={classTypes} rooms={rooms} instructors={instructors}
        draft={{
          id: s.id, name: s.name,
          class_type_id: s.class_type_id, room_id: s.room_id, instructor_id: s.instructor_id,
          capacity: s.capacity, duration_minutes: s.duration_minutes,
          starts_on: s.starts_on,
          // UNTIL and ends_on are one fact; the generator already takes the
          // earlier of them, so the form shows one control and writes ends_on.
          ends_on: s.ends_on ?? until,
          time_of_day: s.time_of_day, description: s.description,
          rule, unsupported,
        }}
      />
    
      <SeriesLifecycle
        id={s.id}
        name={s.name}
        archived={s.status === "archived"}
        endsOn={s.ends_on}
        today={studioToday(ctx.timeZone)}
      />
    </AppShell>
  );
}
