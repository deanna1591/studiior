import Link from "next/link";
import { isDeskUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { money, studioToday } from "@/lib/dashboard";
import { fmtTime } from "@/lib/time";
import { AppShell, Denied, Empty, Rows } from "@/components/ui";

export const dynamic = "force-dynamic";

/**
 * Decision 86. Where the revenue card lands: every payment that made today's
 * total, one row each. The list total is the same number the card shows,
 * because `dashboard_payments_on` shares the exact predicate the card's
 * `studio_revenue_between` uses — succeeded or partially refunded, bucketed on
 * when the money moved. Desk-up: front desk takes the money and reconciles the
 * till, so this is their screen.
 */

type PaymentRow = {
  payment_id: string;
  paid_at: string;
  member_id: string | null;
  member_name: string | null;
  item: string;
  amount_cents: number;
  currency: string;
  method: string;
  recorded_by: string | null;
};

export default async function RevenueTodayPage() {
  const screen = await staffScreen("/dashboard/revenue/today");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isDeskUp(ctx.role)) {
    return <AppShell {...shell} title="Today's takings"><Denied what="payments" role={ctx.role} /></AppShell>;
  }

  const today = studioToday(ctx.timeZone);
  const { data, error } = await supabase.rpc("dashboard_payments_on", {
    p_studio_id: ctx.studioId,
    p_date: today,
  });
  const rows = (data ?? []) as PaymentRow[];
  const total = rows.reduce((s, r) => s + r.amount_cents, 0);
  const currency = rows[0]?.currency ?? "GBP";

  return (
    <AppShell
      {...shell}
      title="Today's takings"
      actions={
        <Link href="/" className="text-[13px] text-ink-3 underline underline-offset-4 hover:text-ink">
          Back to the dashboard
        </Link>
      }
    >
      {error ? (
        <div className="rounded-lg border-l-[3px] border-coral bg-coral-tint px-3 py-2.5">
          <p className="text-[13px] leading-[19px] text-ink">
            Today&rsquo;s payments could not be read. This is not a day with no takings.
          </p>
          <p className="num mt-1.5 text-[11px] leading-4 text-ink-2">{error.message}</p>
        </div>
      ) : rows.length === 0 ? (
        <Empty>No money has come in yet today. Payments appear here the moment they are recorded.</Empty>
      ) : (
        <>
          <div className="panel mb-3 flex items-baseline justify-between p-4">
            <span className="section-label text-ink-2">
              {rows.length} payment{rows.length === 1 ? "" : "s"} today
            </span>
            <span className="num text-[20px] font-semibold leading-6 text-ink">{money(total, currency)}</span>
          </div>
          <Rows>
            {rows.map((r) => (
              <div key={r.payment_id} className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 px-3 py-2.5">
                <span className="flex min-w-0 flex-col">
                  <span className="truncate text-[14px] font-medium leading-5 text-ink">
                    {r.member_name ? (
                      <Link href={`/members/${r.member_id}`} className="hover:underline underline-offset-2">
                        {r.member_name}
                      </Link>
                    ) : (
                      "Walk-in"
                    )}
                  </span>
                  <span className="text-[12px] leading-4 text-ink-3">
                    {r.item}
                    {" · "}<span className="num">{fmtTime(r.paid_at, ctx.timeZone, ctx.timeFormat)}</span>
                    {" · "}{r.method}
                    {r.recorded_by && <>{" · by "}{r.recorded_by}</>}
                  </span>
                </span>
                <span className="num text-[14px] font-semibold leading-5 text-ink">
                  {money(r.amount_cents, r.currency)}
                </span>
              </div>
            ))}
          </Rows>
        </>
      )}
    </AppShell>
  );
}
