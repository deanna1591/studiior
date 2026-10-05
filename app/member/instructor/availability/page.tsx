import Link from "next/link";
import { instructorScreen } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";
import PhoneAvailabilityEditor from "./editor";
import { STATUS_LINE, statusHelp, type Day } from "@/lib/availability";

export const dynamic = "force-dynamic";

/**
 * MY AVAILABILITY — the editor, on the phone (Decision 45).
 *
 * No longer a read-only view with a link out to the desktop: an instructor
 * enters and submits the month from here. Same month-submission mechanism the
 * desktop uses (`availability_submission_week` / `submit_availability`; draft →
 * submitted → approved / changes_requested; the whole week saved as ONE
 * payload). The editor itself is the client component; this screen resolves
 * which month is being collected and reads back whatever is on file for it.
 *
 * Rendered in the shell's bare mode — a focused task screen whose sticky save
 * bar owns the bottom edge — with a step back to Me.
 */
export default async function AvailabilityPage({
  searchParams,
}: { searchParams: { p?: string } }) {
  const { ctx, supabase } = await instructorScreen();

  // The month being collected: next month by default, ?p=YYYY-MM-01 for another.
  const nextMonth = new Date();
  nextMonth.setUTCDate(1);
  nextMonth.setUTCMonth(nextMonth.getUTCMonth() + 1);
  const period = searchParams.p ?? nextMonth.toISOString().slice(0, 10);

  const [{ data }, { data: pub }] = await Promise.all([
    supabase.rpc("availability_submission_week", {
      p_instructor_id: ctx.instructor_id, p_period_start: period,
    }),
    // Decision 46: a published month is locked to the instructor. A
    // schedule_publications row exists only when publication is on AND the month
    // was published — the same source submit_availability's PT409 uses, and
    // readable by staff (which an instructor is).
    supabase.from("schedule_publications").select("id")
      .eq("studio_id", ctx.studio_id).eq("month", period).maybeSingle(),
  ]);
  const sub = data as unknown as {
    status: string; source?: string; note: string | null;
    period_start: string; pattern_ends_on?: string | null; days: Day[];
  } | null;

  const status = sub?.status ?? "none";
  const source = sub?.source ?? "none";
  const publishedLock = !!pub;
  // Decision 46 amendment: the studio entered a standing weekly pattern and no
  // submission exists — show it read-only (the studio owns it), never the "not
  // sent yet" line. A published month takes precedence (its lock sentence wins).
  const patternMode = source === "pattern" && !publishedLock;
  const locked = status === "approved" || publishedLock || patternMode;
  const label = new Intl.DateTimeFormat("en-GB", {
    month: "long", year: "numeric", timeZone: "UTC",
  }).format(new Date(`${period}T12:00:00Z`));
  const patternThrough = sub?.pattern_ends_on
    ? ` through ${new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" })
        .format(new Date(`${sub.pattern_ends_on}T12:00:00Z`))}`
    : "";

  return (
    <InstructorShell ctx={ctx} title={`Availability — ${label}`} bare>
      <Link href="/instructor/me"
            className="m-sub mb-4 inline-flex items-center gap-1 text-ink-3">
        ‹ Me
      </Link>

      {status === "changes_requested" && source === "submission" && sub?.note && (
        <div className="mb-4 border-l-[3px] px-3 py-2.5"
             style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}>
          <p className="m-sub text-ink-2">The studio asked for a change:</p>
          <p className="mt-0.5 text-[14px] leading-5 text-ink">{sub.note}</p>
        </div>
      )}

      <p className="mb-5 text-[13px] leading-5 text-ink-2">
        {patternMode
          ? <>The studio has your {label} availability on file — weekly pattern{patternThrough}. Ask the studio if something has changed.</>
          : <>{STATUS_LINE[status] ?? STATUS_LINE.none}{" "}{statusHelp(status, locked)}</>}
      </p>

      <PhoneAvailabilityEditor
        instructorId={ctx.instructor_id}
        periodStart={period}
        initial={sub?.days ?? []}
        status={status}
        locked={locked}
      />

      {publishedLock ? (
        <p className="m-sub mt-5 text-ink-3">
          This month&rsquo;s schedule is already published — ask the studio if
          something has changed. Your booking and class emails are unaffected.
        </p>
      ) : status === "approved" && (
        <p className="m-sub mt-5 text-ink-3">
          This month is approved and the studio is scheduling around it. To
          change it, ask them to reopen the month.
        </p>
      )}
    </InstructorShell>
  );
}
