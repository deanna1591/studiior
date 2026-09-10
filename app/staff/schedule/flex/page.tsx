import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, Empty, NavLink, SectionLabel } from "@/components/ui";
import { studioToday } from "@/lib/tz";
import Guarantee from "./panel";

export const dynamic = "force-dynamic";

type Pending = {
  occ_id: string; occ_name: string; local_when: string;
  booked: number; minimum: number; short_by: number;
  due_at: string; past_due: boolean;
};

/**
 * Tonight's decisions, in one place.
 *
 * Decision 21. Members never see any of this — a class that might not run looks
 * exactly like one that will, because telling somebody a class is short is
 * telling them not to bother booking it. This screen is the whole of the
 * studio's side of that.
 */
export default async function FlexDecisions() {
  const screen = await staffScreen("/schedule/flex");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return (
      <AppShell {...shell} title="Flex classes">
        <Denied what="The timetable" role={ctx.role} />
      </AppShell>
    );
  }

  const today = studioToday(ctx.timeZone);
  const from = new Date(`${today}T00:00:00Z`);
  from.setUTCDate(from.getUTCDate() - 30);

  const [{ data: settings }, { data: pendingData, error }, { data: reportData }] =
    await Promise.all([
      supabase.from("studio_settings")
        .select("flex_enabled, flex_deadline_mode, flex_deadline_time, flex_deadline_hours")
        .eq("studio_id", ctx.studioId).maybeSingle(),
      supabase.rpc("flex_pending", { p_studio_id: ctx.studioId }),
      supabase.rpc("flex_report", {
        p_studio_id: ctx.studioId,
        p_from: from.toISOString().slice(0, 10), p_to: today,
      }),
    ]);

  if (!settings?.flex_enabled) {
    return (
      <AppShell {...shell} title="Flex classes"
                actions={<NavLink href="/schedule">Back to the schedule</NavLink>}>
        <Empty>
          Flex classes are switched off. Every class runs whatever the headcount,
          which is how this studio works today. Turning it on lets a series run
          only if it reaches a minimum by a deadline — and members never see the
          difference either way.
        </Empty>
      </AppShell>
    );
  }

  if (error) {
    return (
      <AppShell {...shell} title="Flex classes">
        <div className="max-w-[62ch] border-l-[3px] px-3.5 py-3" role="alert"
             style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}>
          <p className="text-[13px] leading-[19px] text-ink">
            The pending list could not be read, so this is not an empty night — it
            is a failure.
          </p>
          <p className="num mt-2 text-[12px] leading-[17px] text-ink-2">{error.message}</p>
        </div>
      </AppShell>
    );
  }

  const pending = (pendingData ?? []) as unknown as Pending[];
  const report = reportData as unknown as {
    flex: { total: number; ran: number; cancelled: number; fill_pct: number };
    core: { total: number; cancelled: number; fill_pct: number };
    by_series: { series_id: string; name: string; ran: number; cancelled: number; fill_pct: number }[];
  } | null;

  const short = pending.filter((p) => p.short_by > 0);
  const ready = pending.filter((p) => p.short_by === 0);
  const deadline = settings.flex_deadline_mode === "hours_before"
    ? `${settings.flex_deadline_hours} hours before each class`
    : `${settings.flex_deadline_time?.slice(0, 5)} the night before`;

  return (
    <AppShell {...shell} title="Flex classes"
              actions={<NavLink href="/schedule">Back to the schedule</NavLink>}>
      <p className="mb-6 max-w-[62ch] text-[13px] leading-[20px] text-ink-2">
        These decide at <strong>{deadline}</strong>. A class that reaches its
        minimum runs and nobody hears anything; one that does not is cancelled and
        the coach is told either way. Members never see that a class was in doubt.
      </p>

      <section className="mb-10">
        <SectionLabel>Short — {short.length}</SectionLabel>
        {short.length === 0 ? (
          <p className="mt-2 text-[13px] leading-[20px] text-ink-3">
            Nothing is short. Every flex class waiting on a decision has its numbers.
          </p>
        ) : (
          <ul className="mt-2 divide-y divide-line rounded-xl border border-line bg-surface">
            {short.map((p) => (
              <li key={p.occ_id}
                  className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2 px-3.5 py-3">
                <div className="min-w-0">
                  <Link href={`/roster/${p.occ_id}`}
                        className="text-[14px] leading-5 text-ink hover:underline">
                    {p.occ_name}
                  </Link>
                  <div className="text-[12px] leading-4 text-ink-3">
                    {p.local_when} · <span className="num">{p.booked}</span>/
                    <span className="num">{p.minimum}</span> —{" "}
                    <span style={{ color: "var(--coral)" }}>
                      {p.short_by} short
                    </span>
                    {p.past_due && <> · decision is due now</>}
                  </div>
                </div>
                <Guarantee occurrenceId={p.occ_id} />
              </li>
            ))}
          </ul>
        )}
      </section>

      {ready.length > 0 && (
        <section className="mb-10">
          <SectionLabel>Have their numbers — {ready.length}</SectionLabel>
          <ul className="mt-2 divide-y divide-line rounded-xl border border-line bg-surface">
            {ready.map((p) => (
              <li key={p.occ_id} className="px-3.5 py-2.5">
                <span className="text-[14px] leading-5 text-ink-2">{p.occ_name}</span>
                <span className="text-[12px] leading-4 text-ink-3">
                  {" "}· {p.local_when} · <span className="num">{p.booked}</span>/
                  <span className="num">{p.minimum}</span>
                </span>
              </li>
            ))}
          </ul>
        </section>
      )}

      {report && (report.flex.total > 0 || report.core.total > 0) && (
        <section>
          <SectionLabel>Last 30 days</SectionLabel>
          <p className="mt-2 max-w-[62ch] text-[13px] leading-[20px] text-ink-2">
            Flex: <span className="num text-ink">{report.flex.ran}</span> ran,{" "}
            <span className="num text-ink">{report.flex.cancelled}</span> cancelled,{" "}
            <span className="num text-ink">{report.flex.fill_pct}%</span> full.
            {" "}Core: <span className="num text-ink">{report.core.fill_pct}%</span> full.
            {" "}Fill is measured on the classes that ran — a cancelled class has no
            fill rate, and averaging its zero in would argue against the slots that
            are working.
          </p>
          {report.by_series.length > 0 && (
            <ul className="mt-3 divide-y divide-line rounded-xl border border-line bg-surface">
              {report.by_series.map((s) => (
                <li key={s.series_id}
                    className="flex items-baseline justify-between gap-4 px-3.5 py-2.5">
                  <Link href={`/series/${s.series_id}`}
                        className="text-[14px] leading-5 text-ink hover:underline">{s.name}</Link>
                  <span className="num text-[12.5px] text-ink-2">
                    {s.ran} ran · {s.cancelled} off · {s.fill_pct}% full
                  </span>
                </li>
              ))}
            </ul>
          )}
          <p className="mt-2 max-w-[62ch] text-[12.5px] leading-[18px] text-ink-3">
            A flex slot filling as well as the core one beside it has earned core
            status. That is the number this is for.
          </p>
        </section>
      )}
    </AppShell>
  );
}
