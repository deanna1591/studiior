import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, Empty, SectionLabel } from "@/components/ui";
import ReviewControls from "./review";

export const dynamic = "force-dynamic";

type CycleRow = {
  instructor_id: string; name: string; has_login: boolean;
  submission_id: string | null; status: string; submitted_at: string | null;
};

const LABEL: Record<string, string> = {
  none: "Nothing sent",
  draft: "Started, not sent",
  submitted: "Waiting for you",
  approved: "Approved",
  changes_requested: "Sent back",
};

/**
 * One place for the month's submissions, and — the point of it — for who has
 * not sent one. Chasing six people by message is the work this removes, so the
 * list of who is missing sits above the list of who is done.
 */
export default async function AvailabilityInbox({
  searchParams,
}: { searchParams: { p?: string } }) {
  const screen = await staffScreen("/availability");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return (
      <AppShell {...shell} title="Availability">
        <Denied what="Reviewing availability" role={ctx.role} />
      </AppShell>
    );
  }

  const [{ data: cycleData }, { data: unconfirmedData }] = await Promise.all([
    supabase.rpc("availability_cycle", {
      p_studio_id: ctx.studioId, p_period_start: searchParams.p ?? undefined,
    }),
    supabase.rpc("unconfirmed_summary", { p_studio_id: ctx.studioId }),
  ]);

  const cycle = cycleData as unknown as {
    period_start: string; due_on: string; due_day: number; overdue: boolean;
    days_left: number; instructors: CycleRow[];
    awaiting_review: number; not_submitted: number;
  } | null;
  const unconfirmed = unconfirmedData as unknown as {
    line: string | null;
    detail: { instructor_id: string; name: string; classes: number;
              list: { occurrence_id: string; name: string; local: string }[] }[];
  } | null;

  if (!cycle) {
    return <AppShell {...shell} title="Availability"><Empty>Nothing to show.</Empty></AppShell>;
  }

  const fmt = (d: string, opts: Intl.DateTimeFormatOptions) =>
    new Intl.DateTimeFormat("en-GB", { ...opts, timeZone: ctx.timeZone })
      .format(new Date(`${d}T12:00:00Z`));
  const month = fmt(cycle.period_start, { month: "long", year: "numeric" });
  const due = fmt(cycle.due_on, { day: "numeric", month: "long" });

  const missing = cycle.instructors.filter(
    (i) => i.status !== "submitted" && i.status !== "approved");
  const waiting = cycle.instructors.filter((i) => i.status === "submitted");
  const done = cycle.instructors.filter((i) => i.status === "approved");

  return (
    <AppShell {...shell} title={`Availability — ${month}`}>
      {/* The confirmation line lives here too. One line, never one per class. */}
      {unconfirmed?.line && (
        <section className="mb-6 border-l-[3px] px-3 py-2.5"
                 style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}>
          <p className="text-[13px] leading-[18px] text-ink">{unconfirmed.line}.</p>
          <ul className="mt-1.5 space-y-0.5">
            {(unconfirmed.detail ?? []).map((d) => (
              <li key={d.instructor_id} className="text-[12.5px] leading-[18px] text-ink-2">
                <Link href={`/my/week?i=${d.instructor_id}`}
                      className="underline underline-offset-4">{d.name}</Link>
                {" — "}
                {d.list.map((c) => `${c.name} ${c.local}`).join("; ")}
              </li>
            ))}
          </ul>
          <p className="mt-1.5 text-[12px] leading-4 text-ink-2">
            Nothing has been released. These classes still have their instructor —
            what to do about them is yours to decide.
          </p>
        </section>
      )}

      <p className="mb-5 max-w-[58ch] text-[13px] leading-[20px] text-ink-2">
        Patterns for {month} are due on <strong>{due}</strong>, the{" "}
        {cycle.due_day}
        {cycle.due_day % 10 === 1 && cycle.due_day !== 11 ? "st"
          : cycle.due_day % 10 === 2 && cycle.due_day !== 12 ? "nd"
          : cycle.due_day % 10 === 3 && cycle.due_day !== 13 ? "rd" : "th"}{" "}
        of the month before.{" "}
        {cycle.overdue
          ? "That date has passed; whoever is still missing is being reminded daily."
          : `${cycle.days_left} days to go.`}
      </p>

      {missing.length > 0 && (
        <section className="mb-8">
          <SectionLabel>Not sent yet — {missing.length}</SectionLabel>
          <ul className="mt-2 divide-y divide-line rounded-xl border border-line bg-surface">
            {missing.map((i) => (
              <li key={i.instructor_id}
                  className="flex flex-wrap items-baseline justify-between gap-x-4 px-3.5 py-2.5">
                <span className="text-[14px] leading-5 text-ink">{i.name}</span>
                <span className="text-[12px] leading-4 text-ink-3">
                  {LABEL[i.status] ?? i.status}
                  {!i.has_login && " · no login, so no reminder can reach them"}
                </span>
              </li>
            ))}
          </ul>
          <p className="mt-2 max-w-[58ch] text-[12px] leading-[18px] text-ink-3">
            You can type somebody&rsquo;s pattern in for them from their
            instructor page — entering it yourself counts as approving it.
          </p>
        </section>
      )}

      <section className="mb-8">
        <SectionLabel>Waiting for you — {waiting.length}</SectionLabel>
        {waiting.length === 0 ? (
          <p className="mt-2 text-[13px] leading-[20px] text-ink-3">Nothing to review.</p>
        ) : (
          <ul className="mt-2 divide-y divide-line rounded-xl border border-line bg-surface">
            {waiting.map((i) => (
              <li key={i.instructor_id} className="px-3.5 py-3">
                <div className="flex flex-wrap items-baseline justify-between gap-x-4">
                  <Link href={`/instructors/${i.instructor_id}/availability`}
                        className="text-[14px] leading-5 text-lime-text underline underline-offset-4">
                    {i.name}
                  </Link>
                  <span className="text-[12px] leading-4 text-ink-3">
                    Sent {i.submitted_at ? fmt(i.submitted_at.slice(0, 10),
                      { day: "numeric", month: "short" }) : ""}
                  </span>
                </div>
                {i.submission_id && <ReviewControls submissionId={i.submission_id} />}
              </li>
            ))}
          </ul>
        )}
      </section>

      {done.length > 0 && (
        <section>
          <SectionLabel>Approved — {done.length}</SectionLabel>
          <ul className="mt-2 divide-y divide-line rounded-xl border border-line bg-surface">
            {done.map((i) => (
              <li key={i.instructor_id} className="px-3.5 py-2.5 text-[14px] leading-5 text-ink-2">
                {i.name}
              </li>
            ))}
          </ul>
        </section>
      )}
    </AppShell>
  );
}
