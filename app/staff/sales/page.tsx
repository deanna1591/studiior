import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { studioToday } from "@/lib/dashboard";
import { dayMonthParts } from "@/lib/time";
import { formatMoney } from "@/lib/plans";
import { AppShell, Denied, Empty } from "@/components/ui";
import { StateChip } from "@/components/state-chip";
import MembershipActions from "../members/[id]/membership-actions-panel";

export const dynamic = "force-dynamic";

/**
 * Decision 49 — every plan purchase, newest first.
 *
 * Manager-up: the member overview (desk-up) carries plan state with no money;
 * this is the money, so it is held to the same bar as Revenue. Every figure is
 * the database's — sales_history for the rows, sales_totals for the line, both
 * reusing the revenue definition so Sales and the dashboard cannot disagree.
 */

const STATUSES: [string, string][] = [
  ["active", "Active"],
  ["expiring", "Expiring"],
  ["expired", "Expired"],
  ["refunded", "Refunded"],
  ["unpaid", "Unpaid"],
  ["frozen", "Paused"],
];

type Sale = {
  membership_id: string; member_id: string; member_name: string;
  plan_id: string; plan_name: string; plan_type: string;
  amount_cents: number; currency: string; payment_source: string;
  bought_on: string; starts_on: string | null; expires_on: string | null;
  sale_status: string;
};

type Totals = {
  count: number; gross_cents: number; refunded_cents: number;
  net_cents: number; studio_total_cents: number; currency: string;
};

export default async function Sales({
  searchParams,
}: {
  searchParams: { plan?: string; status?: string; month?: string };
}) {
  const screen = await staffScreen("/sales");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Sales"><Denied what="sales" role={ctx.role} /></AppShell>;
  }

  const todayStr = studioToday(ctx.timeZone);
  const currentMonth = todayStr.slice(0, 7);
  // ?month=this (or anything not YYYY-MM) means the current studio-local month.
  const ym = /^\d{4}-\d{2}$/.test(searchParams.month ?? "") ? searchParams.month! : currentMonth;
  const [yy, mm] = ym.split("-").map(Number);
  const lastDay = new Date(Date.UTC(yy, mm, 0)).getUTCDate();
  const from = `${ym}-01`;
  const to = `${ym}-${String(lastDay).padStart(2, "0")}`;

  const planId = searchParams.plan || null;
  const status = searchParams.status || null;

  const [{ data: plans }, salesRes, totalsRes] = await Promise.all([
    supabase.from("membership_plans").select("id, name").order("name"),
    supabase.rpc("sales_history", {
      p_studio_id: ctx.studioId, p_from: from, p_to: to,
      p_plan_id: planId ?? undefined, p_status: status ?? undefined,
    }),
    supabase.rpc("sales_totals", {
      p_studio_id: ctx.studioId, p_from: from, p_to: to,
      p_plan_id: planId ?? undefined, p_status: status ?? undefined,
    }),
  ]);

  const sales = (salesRes.data ?? []) as Sale[];
  const totals = (totalsRes.data ?? null) as Totals | null;
  const error = salesRes.error?.message ?? totalsRes.error?.message ?? null;

  const exportQuery = new URLSearchParams();
  exportQuery.set("month", ym);
  if (planId) exportQuery.set("plan", planId);
  if (status) exportQuery.set("status", status);

  const d = (iso: string | null) => {
    if (!iso) return <span className="text-ink-3">—</span>;
    const { day, month } = dayMonthParts(iso, ctx.timeZone);
    return <><span className="num">{day}</span> {month}</>;
  };

  return (
    <AppShell
      {...shell}
      title="Sales"
      actions={
        <>
          <Link href={`/sales/export?${exportQuery.toString()}`}
                className="text-[13px] leading-[18px] text-lime-text underline underline-offset-4 hover:text-lime-text2">
            Export CSV
          </Link>
          <Link href="/dashboard/revenue"
                className="text-[13px] text-ink-3 underline underline-offset-4 hover:text-ink">
            Revenue
          </Link>
        </>
      }
      filters={
        <form action="/sales" className="flex flex-wrap items-end gap-3">
          <label className="block">
            <span className="mb-1 block text-[12px] leading-4 text-ink-2">Month</span>
            <input type="month" name="month" defaultValue={ym}
                   className="rounded border border-line-2 bg-surface px-2 py-1.5 text-[13px] text-ink" />
          </label>
          <label className="block">
            <span className="mb-1 block text-[12px] leading-4 text-ink-2">Plan</span>
            <select name="plan" defaultValue={planId ?? ""}
                    className="rounded border border-line-2 bg-surface px-2 py-1.5 text-[13px] text-ink">
              <option value="">All plans</option>
              {(plans ?? []).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select>
          </label>
          <label className="block">
            <span className="mb-1 block text-[12px] leading-4 text-ink-2">Status</span>
            <select name="status" defaultValue={status ?? ""}
                    className="rounded border border-line-2 bg-surface px-2 py-1.5 text-[13px] text-ink">
              <option value="">Any status</option>
              {STATUSES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
            </select>
          </label>
          <button className="rounded bg-ink px-3 py-2 text-[13px] font-medium leading-[18px] text-paper hover:bg-ink-2">
            Show
          </button>
        </form>
      }
    >
      {totals && (
        <p className="mb-4 text-[13px] leading-[19px] text-ink-2">
          <span className="num text-ink">{totals.count}</span> purchase{totals.count === 1 ? "" : "s"}
          {" · "}<span className="num text-ink">{formatMoney(totals.gross_cents, totals.currency)}</span> gross
          {totals.refunded_cents > 0 && (
            <> · <span className="num">{formatMoney(totals.refunded_cents, totals.currency)}</span> refunded</>
          )}
          {" · "}<span className="num text-ink">{formatMoney(totals.net_cents, totals.currency)}</span> net
        </p>
      )}

      {error ? (
        <div className="rounded-lg border-l-[3px] border-coral bg-coral-tint px-3 py-2.5">
          <p className="text-[13px] leading-[19px] text-ink">
            This is not empty — the sales could not be read. Nothing is wrong with your data.
          </p>
          <p className="num mt-1.5 break-words text-[11px] leading-4 text-ink-2">{error}</p>
        </div>
      ) : sales.length === 0 ? (
        <Empty>
          No purchases in {ym}
          {(planId || status) ? " for that filter" : ""}. Pick another month, or
          clear the filters.
        </Empty>
      ) : (
        <div className="overflow-x-auto border-y border-line bg-surface">
          <table className="w-full min-w-[840px] border-collapse">
            <thead>
              <tr className="border-b border-line text-left text-[10px] uppercase leading-4 tracking-[0.06em] text-ink-3">
                <th className="px-3 py-2 font-medium">Member</th>
                <th className="px-3 py-2 font-medium">Plan</th>
                <th className="px-3 py-2 font-medium">Paid by</th>
                <th className="px-3 py-2 text-right font-medium">Amount</th>
                <th className="px-3 py-2 font-medium">Bought</th>
                <th className="px-3 py-2 font-medium">Starts</th>
                <th className="px-3 py-2 font-medium">Expires</th>
                <th className="px-3 py-2 font-medium">Status</th>
                <th className="px-3 py-2 font-medium"></th>
              </tr>
            </thead>
            <tbody className="divide-y divide-line">
              {sales.map((s) => (
                <tr key={s.membership_id} className="align-top text-[13px] leading-5 text-ink">
                  <td className="px-3 py-2.5">
                    <Link href={`/members/${s.member_id}`}
                          className="text-ink underline underline-offset-4 decoration-line-2 hover:decoration-ink">
                      {s.member_name}
                    </Link>
                  </td>
                  <td className="px-3 py-2.5">
                    <span className="block">{s.plan_name}</span>
                    <span className="block text-[11px] leading-4 text-ink-3">{s.plan_type.replace("_", " ")}</span>
                  </td>
                  <td className="px-3 py-2.5 text-ink-2">{s.payment_source}</td>
                  <td className="num px-3 py-2.5 text-right">{formatMoney(s.amount_cents, s.currency)}</td>
                  <td className="px-3 py-2.5 text-ink-2">{d(s.bought_on)}</td>
                  <td className="px-3 py-2.5 text-ink-2">{d(s.starts_on)}</td>
                  <td className="px-3 py-2.5 text-ink-2">{d(s.expires_on)}</td>
                  <td className="px-3 py-2.5"><StateChip state={s.sale_status} /></td>
                  <td className="px-3 py-2.5">
                    <MembershipActions
                      compact
                      membershipId={s.membership_id}
                      frozen={s.sale_status === "frozen"}
                      priceCents={s.amount_cents}
                      currency={s.currency}
                      expiresOn={s.expires_on}
                      today={todayStr}
                    />
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
