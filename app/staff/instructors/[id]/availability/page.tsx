import { notFound } from "next/navigation";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, NavLink, SectionLabel } from "@/components/ui";
import WeekEditor, { type Day } from "./week-editor";
import Exceptions, { type Exception } from "./exceptions";
import CommitmentForm, { type Commitment } from "./commitment";

export const dynamic = "force-dynamic";

/**
 * Decision 18. The screen instructor_availability has been waiting for since
 * migration 001 — the columns were always there and nothing could write them,
 * so every availability warning the scheduler produced was computed against an
 * empty table and happened to be right.
 *
 * Manager-up, or the instructor looking at their own. Both write the same rows,
 * per Decision 9; the commitment is the one thing an instructor reads and
 * cannot change.
 */
export default async function Availability({ params }: { params: { id: string } }) {
  const screen = await staffScreen("/instructors");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  const { data: i } = await supabase.from("instructors")
    .select("id, display_name, status").eq("id", params.id).maybeSingle();
  if (!i) notFound();

  const { data: me } = await supabase.rpc("auth_instructor_id", { target: ctx.studioId });
  const isThem = me === i.id;
  const manager = isManagerUp(ctx.role);
  if (!manager && !isThem) {
    return (
      <AppShell {...shell} title={i.display_name}>
        <Denied what="Setting someone else's availability" role={ctx.role} />
      </AppShell>
    );
  }

  const [{ data: week }, { data: commitment }, { data: load }] = await Promise.all([
    supabase.rpc("instructor_availability_week", { p_instructor_id: i.id }),
    supabase.from("instructor_commitments")
      .select("id, starts_on, ends_on, min_per_week, target_per_week, shift_preference")
      .eq("instructor_id", i.id).eq("status", "active").maybeSingle(),
    supabase.rpc("instructor_weekly_load", { p_instructor_id: i.id, p_weeks: 6 }),
  ]);

  const w = (week ?? {}) as {
    days?: Day[]; effective_from?: string | null; effective_to?: string | null;
    exceptions?: Exception[];
  };

  const fmt = (d: string) =>
    new Intl.DateTimeFormat("en-GB", {
      timeZone: ctx.timeZone, weekday: "short", day: "numeric", month: "short", year: "numeric",
    }).format(new Date(d + "T12:00:00Z"));

  return (
    <AppShell
      {...shell}
      title={`${i.display_name} — availability`}
      actions={<NavLink href={`/instructors/${i.id}`}>Back to their details</NavLink>}
    >
      <div className="grid gap-8 lg:grid-cols-[minmax(0,1fr)_minmax(0,380px)]">
        <section>
          <SectionLabel>When they are typically available</SectionLabel>
          <p className="mb-4 text-[13px] leading-[20px] text-ink-2">
            A standing pattern, not a week-by-week rota. Assigning a class
            outside it is allowed and warned about, never blocked.
          </p>
          <WeekEditor
            instructorId={i.id}
            initial={w.days ?? []}
            effectiveFrom={w.effective_from ?? null}
            effectiveTo={w.effective_to ?? null}
            canEdit={manager || isThem}
          />
        </section>

        <div className="space-y-8">
          <section>
            <SectionLabel>Adjust specific days</SectionLabel>
            <Exceptions
              instructorId={i.id}
              exceptions={(w.exceptions ?? []).map((e) => ({ ...e, label: fmt(e.date) }))}
              canEdit={manager || isThem}
            />
          </section>

          <section>
            <SectionLabel>Commitment</SectionLabel>
            <CommitmentForm
              instructorId={i.id}
              name={i.display_name}
              commitment={(commitment ?? null) as Commitment}
              canEdit={manager}
              load={(load ?? []) as { week_start: string; classes: number }[]}
            />
          </section>
        </div>
      </div>
    </AppShell>
  );
}
