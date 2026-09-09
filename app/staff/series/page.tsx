import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { SetupShell, SetupRow, ArchivedSection } from "@/components/setup-list";
import { parseRrule, describeRule } from "@/lib/rrule";

export const dynamic = "force-dynamic";

export default async function SeriesList() {
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

  const { data: series } = await supabase
    .from("class_series")
    .select("id, name, rrule, time_of_day, ends_on, status, capacity, instructor_id")
    .order("status").order("time_of_day");

  const live = (series ?? []).filter((s) => s.status === "active");
  const gone = (series ?? []).filter((s) => s.status !== "active");

  // Described on the server. describeRule is a pure function on both sides, but
  // the STRING crosses the boundary, never the function.
  const meta = (s: (typeof live)[number]) => {
    const { rule, until, unsupported } = parseRrule(s.rrule);
    if (unsupported) return `Repeat rule Studiior cannot keep (${unsupported})`;
    return describeRule(rule, s.ends_on ?? until, s.time_of_day);
  };

  return (
    <SetupShell
      shell={shell}
      title="Recurring classes"
      blurb="Your standing timetable. A series materialises twelve months of classes and keeps
             itself topped up every night, so a member can always book a month ahead.
             One-off classes are added from the calendar instead."
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
