import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import { formatMoney } from "@/lib/plans";
import { dayMonthLongParts, fmtDayLong } from "@/lib/time";
import { membershipTab, membershipChip, usedOfTotal, paymentRows } from "@/lib/wallet";
import type { Wallet } from "@/lib/wallet";
import PaymentsList, { type PaymentRowView } from "@/components/member/payments-list";

export const dynamic = "force-dynamic";

const TABS = [
  { key: "plans", label: "Plans" },
  { key: "payments", label: "Payments" },
] as const;
type TabKey = (typeof TABS)[number]["key"];

type Row = {
  id: string;
  status: string;
  credits_remaining: number | null;
  expires_on: string | null;
  renews_on: string | null;
  current_period_end: string | null;
  membership_plans: { name: string | null; type: string; credits: number | null } | null;
};

/** Decision 88(c) — one Account home for everything bought: the member's held
 *  plans, and every payment with its invoice. */
export default async function PurchasesScreen({
  searchParams,
}: { searchParams: { tab?: string } }) {
  const { ctx, supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } =
    await memberScreen();

  const tab: TabKey = (TABS.some((t) => t.key === searchParams.tab) ? searchParams.tab : "plans") as TabKey;

  const [{ data: plansData }, { data: walletData }] = await Promise.all([
    supabase
      .from("memberships")
      .select("id, status, credits_remaining, expires_on, renews_on, current_period_end, membership_plans(name, type, credits)")
      .eq("member_id", ctx.memberId)
      .order("starts_on", { ascending: false }),
    supabase.rpc("member_wallet", { p_studio_id: ctx.studioId }),
  ]);

  const rows = (plansData ?? []) as unknown as Row[];
  const subs = rows.filter((m) => membershipTab(m.membership_plans?.type ?? "") === "subscriptions");
  const passes = rows.filter((m) => membershipTab(m.membership_plans?.type ?? "") === "passes");

  const shortDate = (iso: string) => {
    const { day, month } = dayMonthLongParts(iso, ctx.timeZone);
    return `${day} ${month}`;
  };

  // Payments tab rows, formatted server-side (currency + tz) so the client
  // component only toggles filters.
  const pRows: PaymentRowView[] = paymentRows((walletData ?? {}) as Partial<Wallet>).map((r) => ({
    key: r.key,
    kind: r.kind,
    chip: r.chip,
    invoiceable: r.invoiceable,
    paymentId: r.paymentId,
    item: r.item,
    dateLabel: fmtDayLong(r.at, ctx.timeZone),
    amountLabel: formatMoney(r.amount_cents ?? 0, r.currency),
    refundLabel: r.refunded_cents > 0 ? `${formatMoney(r.refunded_cents, r.currency)} refunded` : null,
  }));

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent} title="My purchases">
      <Link href="/account" className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Account
      </Link>
      <h1 className="m-title mb-4 text-ink">My purchases</h1>

      <div className="mb-4 flex flex-wrap gap-2">
        {TABS.map((t) => {
          const active = t.key === tab;
          return (
            <Link key={t.key} href={`/purchases?tab=${t.key}`}
                  className="m-sub m-press rounded-full px-3 py-1.5"
                  style={active
                    ? { background: "var(--accent-chip)", color: "var(--ink)", fontWeight: 700 }
                    : { color: "var(--ink-2)" }}>
              {t.label}
            </Link>
          );
        })}
      </div>

      {tab === "plans" ? (
        <div className="space-y-5">
          <PlanSection title="Subscriptions" empty="No subscriptions yet." rows={subs}
                       validUntil={(m) => m.expires_on ?? m.current_period_end ?? m.renews_on}
                       date={shortDate} pass={false} />
          <PlanSection title="Passes" empty="No passes yet." rows={passes}
                       validUntil={(m) => m.expires_on} date={shortDate} pass />
        </div>
      ) : (
        <PaymentsList rows={pRows} />
      )}
    </MemberShell>
  );
}

function PlanSection({
  title, empty, rows, validUntil, date, pass,
}: {
  title: string; empty: string; rows: Row[];
  validUntil: (m: Row) => string | null; date: (iso: string) => string; pass: boolean;
}) {
  return (
    <section>
      <h2 className="section-label mb-2 text-ink-2">{title}</h2>
      {rows.length === 0 ? (
        <div className="m-card p-5 text-center"><p className="m-body text-ink">{empty}</p></div>
      ) : (
        <ul className="space-y-3">
          {rows.map((m) => {
            const until = validUntil(m);
            const used = pass
              ? usedOfTotal({ plan_credits: m.membership_plans?.credits, credits_remaining: m.credits_remaining })
              : null;
            return (
              <li key={m.id} className="m-card p-4">
                <div className="flex items-start justify-between gap-3">
                  <span className="m-name text-ink">{m.membership_plans?.name ?? "Plan"}</span>
                  <span className="m-micro shrink-0 rounded-full px-2.5 py-0.5"
                        style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>
                    {membershipChip(m.status)}
                  </span>
                </div>
                {until && <p className="m-sub mt-1 text-ink-2">Valid until {date(until)}</p>}
                {used && <p className="m-sub mt-0.5 text-ink-2">{used}</p>}
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
