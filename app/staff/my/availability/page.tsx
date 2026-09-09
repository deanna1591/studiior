import { staffScreen } from "@/lib/screen";
import { AppShell, Empty, Notice, SectionLabel } from "@/components/ui";
import WeekEditor, { type Day } from "@/app/staff/instructors/[id]/availability/week-editor";

export const dynamic = "force-dynamic";

const STATUS_LINE: Record<string, string> = {
  none: "Not sent yet.",
  draft: "Saved as a draft. The studio has not seen it.",
  submitted: "Sent. Waiting for the studio.",
  approved: "Approved. Classes are being scheduled around it.",
  changes_requested: "The studio has asked for a change.",
};

/** Which month is being collected, and when it is due — both from the studio's setting. */
export default async function MyAvailability({
  searchParams,
}: { searchParams: { p?: string } }) {
  const screen = await staffScreen("/my/availability");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  const { data: mine } = await supabase
    .from("instructors").select("id, display_name")
    .eq("staff_id", ctx.staffId).eq("status", "active").maybeSingle();

  if (!mine) {
    return (
      <AppShell {...shell} title="My availability">
        <Empty>
          There is no instructor record attached to this login, so there is
          nothing to submit. A studio manager can link one from Instructors.
        </Empty>
      </AppShell>
    );
  }

  // The cycle is manager-up, so an instructor gets the period and due date from
  // the submission itself rather than from the studio-wide list.
  const nextMonth = new Date();
  nextMonth.setUTCDate(1);
  nextMonth.setUTCMonth(nextMonth.getUTCMonth() + 1);
  const period = searchParams.p ?? nextMonth.toISOString().slice(0, 10);

  const { data } = await supabase.rpc("availability_submission_week", {
    p_instructor_id: mine.id, p_period_start: period,
  });
  const sub = data as unknown as {
    submission_id: string | null; status: string; note: string | null;
    period_start: string; period_end: string; days: Day[];
  } | null;

  const label = new Intl.DateTimeFormat("en-GB", {
    month: "long", year: "numeric", timeZone: ctx.timeZone,
  }).format(new Date(`${period}T12:00:00Z`));

  const status = sub?.status ?? "none";
  const locked = status === "approved";

  return (
    <AppShell {...shell} title={`My availability — ${label}`}>
      {status === "changes_requested" && sub?.note && (
        <Notice kind="error">The studio asked for a change: {sub.note}</Notice>
      )}
      <p className="mb-5 max-w-[58ch] text-[13px] leading-[20px] text-ink-2">
        {STATUS_LINE[status] ?? STATUS_LINE.none}{" "}
        {locked
          ? "To change it now, ask the studio to reopen the month."
          : status === "submitted"
          ? "You can still change it until they look at it."
          : "Fill in the hours you can teach in each day. Copy a day across the week rather than typing it seven times."}
      </p>

      <SectionLabel>{label}</SectionLabel>
      <div className="mt-3">
        <WeekEditor
          instructorId={mine.id}
          initial={sub?.days ?? []}
          effectiveFrom={sub?.period_start ?? period}
          effectiveTo={sub?.period_end ?? null}
          canEdit={!locked}
          submission={{
            periodStart: period, periodLabel: label,
            status, note: sub?.note ?? null,
          }}
        />
      </div>
    </AppShell>
  );
}
