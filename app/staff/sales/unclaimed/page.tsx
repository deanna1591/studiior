import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { dayMonthParts } from "@/lib/time";
import { formatMoney } from "@/lib/plans";
import { formatPhone } from "@/lib/phone";
import { AppShell, Denied, Empty } from "@/components/ui";
import RowActions from "./row-actions";

export const dynamic = "force-dynamic";

type Row = {
  purchase_id: string; payment_id: string | null; buyer_name: string | null; buyer_email: string | null;
  buyer_phone: string | null; plan_name: string; amount_cents: number; currency: string;
  paid_at: string; days_waiting: number; status: string;
};

/**
 * Decision 118: plans bought without an account and not yet claimed. The buyer
 * claims by setting up (or signing in) with the email they paid with. Staff can
 * send the setup email again, or refund before claim, which cancels the plan.
 */
export default async function Unclaimed() {
  const screen = await staffScreen("/sales");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Bought, not yet claimed"><Denied what="sales" role={ctx.role} /></AppShell>;
  }
  const { data, error } = await supabase.rpc("guest_purchases_unclaimed", { p_studio_id: ctx.studioId });
  const rows = (data ?? []) as Row[];
  const d = (iso: string) => {
    const p = dayMonthParts(iso, ctx.timeZone);
    return `${p.day} ${p.month}`;
  };

  return (
    <AppShell {...shell} title="Bought, not yet claimed"
      actions={<Link href="/sales" className="text-[13px] text-ink-3 underline underline-offset-4 hover:text-ink">Sales</Link>}>
      <p className="mb-5 max-w-[60ch] text-[13px] leading-[20px] text-ink-2">
        Plans bought on the website by people without an account. Each one is added to their account
        when they set it up, or sign in, with the email they paid with. The plan starts that day.
      </p>
      {error ? (
        <p className="text-[13px] text-ink">This list could not be loaded: {error.message}</p>
      ) : rows.length === 0 ? (
        <Empty>Nothing waiting. Every plan bought on the website is in an account.</Empty>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full min-w-[720px] text-left text-[13px]">
            <thead className="text-[11px] uppercase tracking-[0.06em] text-ink-3">
              <tr>
                <th className="px-3 py-2 font-medium">Buyer</th>
                <th className="px-3 py-2 font-medium">Plan</th>
                <th className="px-3 py-2 font-medium">Paid</th>
                <th className="px-3 py-2 font-medium">Waiting</th>
                <th className="px-3 py-2 font-medium"></th>
              </tr>
            </thead>
            <tbody className="divide-y divide-line">
              {rows.map((r) => (
                <tr key={r.purchase_id} className="align-top">
                  <td className="px-3 py-2.5">
                    <p className="text-ink">{r.buyer_name ?? r.buyer_email}</p>
                    <p className="text-[12px] text-ink-2">{r.buyer_email}</p>
                    {r.buyer_phone && <a href={`tel:${r.buyer_phone}`} className="text-[12px] text-ink-2 underline underline-offset-4">{formatPhone(r.buyer_phone)}</a>}
                  </td>
                  <td className="px-3 py-2.5 text-ink">
                    {r.plan_name}
                    <span className="num block text-[12px] text-ink-2">{formatMoney(r.amount_cents, r.currency)}</span>
                  </td>
                  <td className="px-3 py-2.5 text-ink-2">{d(r.paid_at)}</td>
                  <td className="px-3 py-2.5 text-ink-2">
                    {r.status === "refund_pending"
                      ? "Intro offer already had; refund it"
                      : `${r.days_waiting} day${r.days_waiting === 1 ? "" : "s"}`}
                  </td>
                  <td className="px-3 py-2.5">
                    <RowActions purchaseId={r.purchase_id} paymentId={r.payment_id} held={r.status === "held"} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </AppShell>
  );
}
