import Link from "next/link";
import { staffScreen } from "@/lib/screen";
import { isDeskUp } from "@/lib/auth";
import { money } from "@/lib/dashboard";
import { AppShell, Denied, Empty, Pill, PillRow, Rows } from "@/components/ui";

export const dynamic = "force-dynamic";

type DueRow = {
  membership_id: string; member_id: string; member_name: string; email: string | null;
  plan_id: string; plan_name: string; owed_cents: number; currency: string;
  status: string; due_on: string; days_overdue: number;
  last_paid_at: string | null; record_href: string; member_href: string;
};
type Due = {
  today: string; currency: string; within_days: number;
  state: "ok" | "clear" | "empty";
  rows: DueRow[];
  overdue_count: number; overdue_cents: number; due_soon_count: number;
  empty_hint: string; clear_hint: string;
};

const WINDOWS = [0, 7, 30];

/**
 * WHO OWES THE STUDIO MONEY.
 *
 * The single most useful screen for a studio with no card provider, and it did
 * not exist anywhere. Decision 16 says a studio may take cash for ever — and
 * until now nothing in the product could tell it who had not paid this month.
 *
 * FRONT DESK, not manager-up. Permissions §9 reads front desk "Payments" as
 * taking payment, and the desk is exactly who chases and records one. This is
 * an operational list, not the revenue analysis §12 note 21 keeps from them.
 *
 * Subscription-backed memberships are absent: Stripe collects those and nobody
 * chases them at a counter.
 */
export default async function DuePage({
  searchParams,
}: { searchParams: { within?: string } }) {
  const screen = await staffScreen("/due");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isDeskUp(ctx.role)) {
    return (
      <AppShell {...shell} title="Payments due">
        <Denied what="payments" role={ctx.role} />
      </AppShell>
    );
  }

  const n = Number(searchParams.within);
  const within = WINDOWS.includes(n) ? n : 7;

  const { data, error } = await supabase.rpc("memberships_due", {
    p_studio_id: ctx.studioId, p_within_days: within,
  });
  const due = data as Due | null;

  const fmtDay = (iso: string) =>
    new Intl.DateTimeFormat("en-GB", {
      timeZone: "UTC", weekday: "short", day: "numeric", month: "short",
    }).format(new Date(`${iso}T00:00:00Z`));

  return (
    <AppShell
      {...shell}
      title="Payments due"
      filters={
        <PillRow>
          <Pill href="/due?within=0" active={within === 0}>Overdue only</Pill>
          <Pill href="/due" active={within === 7}>Next 7 days</Pill>
          <Pill href="/due?within=30" active={within === 30}>Next 30 days</Pill>
        </PillRow>
      }
    >
      {/* A FAILED QUERY MUST NOT LOOK LIKE NOBODY OWING ANYTHING. */}
      {error ? (
        <div className="max-w-[62ch] border-l-[3px] px-3.5 py-3"
             style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}
             role="alert">
          <p className="text-[13px] leading-[19px] text-ink">
            This could not be read, so it is not an empty list — it is a failure.
          </p>
          <p className="num mt-2 break-words text-[12px] leading-[17px] text-ink-2">{error.message}</p>
        </div>
      ) : !due ? null : due.state === "empty" ? (
        <Empty>{due.empty_hint}</Empty>
      ) : due.state === "clear" ? (
        <Empty>{due.clear_hint}</Empty>
      ) : (
        <>
          <p className="mb-4 max-w-[68ch] text-[14px] leading-[21px] text-ink">
            {due.overdue_count > 0 ? (
              <>
                <span className="num font-medium">{due.overdue_count}</span>{" "}
                {due.overdue_count === 1 ? "membership is" : "memberships are"} overdue,
                worth <span className="num font-medium">{money(due.overdue_cents, due.currency)}</span>.
                {due.due_soon_count > 0 && (
                  <> Another <span className="num">{due.due_soon_count}</span>{" "}
                    {due.due_soon_count === 1 ? "falls" : "fall"} due soon.</>
                )}
              </>
            ) : (
              <>
                Nothing overdue. <span className="num font-medium">{due.due_soon_count}</span>{" "}
                {due.due_soon_count === 1 ? "membership falls" : "memberships fall"} due
                in the next {due.within_days} days.
              </>
            )}
          </p>

          <Rows>
            {due.rows.map((r) => (
              <div key={r.membership_id}
                   className="flex flex-wrap items-baseline gap-x-4 gap-y-1 border-y border-line bg-surface px-3 py-3 first:border-t last:border-b">
                <span className="min-w-[168px] flex-1">
                  <Link href={r.member_href}
                        className="text-[14px] font-medium leading-5 text-ink hover:underline hover:underline-offset-4">
                    {r.member_name}
                  </Link>
                  <span className="block text-[12px] leading-4 text-ink-3">{r.plan_name}</span>
                </span>

                <span className="min-w-[132px] text-[12px] leading-4">
                  {r.days_overdue > 0 ? (
                    // Coral sets a numeral here, not a sentence — 4.47 on
                    // white is the palette's rule for large or bold figures.
                    <span className="text-ink">
                      <span className="num font-semibold text-coral-deep">{r.days_overdue}d</span>{" "}
                      overdue
                    </span>
                  ) : (
                    <span className="text-ink-2">due {fmtDay(r.due_on)}</span>
                  )}
                  <span className="block text-ink-3">
                    {r.last_paid_at
                      ? `last paid ${fmtDay(r.last_paid_at.slice(0, 10))}`
                      : "never paid"}
                  </span>
                </span>

                <span className="num min-w-[92px] text-right text-[14px] leading-5 text-ink">
                  {money(r.owed_cents, r.currency)}
                </span>

                <Link href={r.record_href}
                      className="shrink-0 rounded bg-ink px-2.5 py-1.5 text-[12px] font-medium leading-4 text-paper hover:bg-ink-2">
                  Record payment
                </Link>
              </div>
            ))}
          </Rows>

          <p className="mt-3 max-w-[70ch] text-[11px] leading-4 text-ink-3">
            What each owes is the price they agreed when they joined, not the
            plan&rsquo;s price today. Memberships collected by card are not listed
            — those bill themselves. A frozen membership is paused, not overdue.
          </p>
        </>
      )}
    </AppShell>
  );
}
