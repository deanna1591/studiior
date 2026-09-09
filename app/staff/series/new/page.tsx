import { redirect } from "next/navigation";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, NavLink } from "@/components/ui";
import SeriesForm from "../form";
import { localDates, seriesOptions } from "../data";

export const dynamic = "force-dynamic";

export default async function NewSeries() {
  const screen = await staffScreen("/series/new");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return (
      <AppShell {...shell} title="Add a series">
        <Denied what="Changing the timetable" role={ctx.role} />
      </AppShell>
    );
  }

  const { classTypes, rooms, instructors } = await seriesOptions(supabase);
  const { today, tomorrow } = localDates(ctx.timeZone);

  return (
    <AppShell {...shell} title="Add a series"
              actions={<NavLink href="/series">Back to recurring classes</NavLink>}>
      <p className="mb-5 max-w-[54ch] text-[13px] leading-[20px] text-ink-2">
        Saving this puts twelve months of classes on the calendar straight away, and a
        nightly job keeps that horizon rolling forward.
      </p>
      <SeriesForm
        mode="create"
        timeZone={ctx.timeZone}
        tomorrow={tomorrow}
        classTypes={classTypes} rooms={rooms} instructors={instructors}
        draft={{
          name: "", class_type_id: null, room_id: null, instructor_id: null,
          capacity: rooms[0]?.capacity ?? 8,
          duration_minutes: classTypes[0]?.duration ?? 50,
          starts_on: today, ends_on: null, time_of_day: "07:00",
          description: null, rule: { days: [], interval: 1, count: null },
          unsupported: null,
        }}
      />
    </AppShell>
  );
}
