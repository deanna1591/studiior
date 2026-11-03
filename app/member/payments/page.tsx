import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import { formatMoney } from "@/lib/plans";
import { fmtDayLong, fmtClock } from "@/lib/time";
import { walletBuckets, onlineStatusLabel } from "@/lib/wallet";
import type { Wallet } from "@/lib/wallet";

export const dynamic = "force-dynamic";

const TABS = [
  { key: "unpaid", label: "Unpaid" },
  { key: "paid", label: "Paid" },
  { key: "refunded", label: "Refunded" },
  { key: "desk", label: "Pay at the desk" },
] as const;
type TabKey = (typeof TABS)[number]["key"];

const EMPTY: Record<TabKey, string> = {
  unpaid: "No unpaid payments.",
  paid: "No payments yet.",
  refunded: "No refunds.",
  desk: "Nothing owed at the desk.",
};

function Chip({ children }: { children: React.ReactNode }) {
  return (
    <span className="m-micro shrink-0 rounded-full px-2.5 py-0.5"
          style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>
      {children}
    </span>
  );
}

export default async function PaymentsScreen({
  searchParams,
}: { searchParams: { tab?: string } }) {
  const { ctx, supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } =
    await memberScreen();

  const { data } = await supabase.rpc("member_wallet", { p_studio_id: ctx.studioId });
  const { unpaid, paid, refunded, desk } = walletBuckets((data ?? {}) as Partial<Wallet>);

  const tab: TabKey = (TABS.some((t) => t.key === searchParams.tab) ? searchParams.tab : "paid") as TabKey;
  const fmt = ctx.timeFormat;
  const date = (iso: string) => fmtDayLong(iso, ctx.timeZone);

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent} title="Payments">
      <Link href="/account" className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Account
      </Link>
      <h1 className="m-title mb-4 text-ink">Payments</h1>

      <div className="mb-4 flex flex-wrap gap-2">
        {TABS.map((t) => {
          const active = t.key === tab;
          return (
            <Link key={t.key} href={`/payments?tab=${t.key}`}
                  className="m-sub m-press rounded-full px-3 py-1.5"
                  style={active
                    ? { background: "var(--accent-chip)", color: "var(--ink)", fontWeight: 700 }
                    : { color: "var(--ink-2)" }}>
              {t.label}
            </Link>
          );
        })}
      </div>

      {tab === "unpaid" && (
        unpaid.length === 0 ? <Empty>{EMPTY.unpaid}</Empty> : (
          <ul className="m-card divide-y divide-line overflow-hidden">
            {unpaid.map((p) => (
              <li key={p.id} className="flex items-start justify-between gap-3 px-4 py-3">
                <span className="min-w-0">
                  <span className="m-body block text-ink">{p.item}</span>
                  <span className="m-micro block text-ink-3">{date(p.at)} · {onlineStatusLabel(p.status)}</span>
                </span>
                <span className="num shrink-0 text-[15px] text-ink">{formatMoney(p.amount_cents, p.currency)}</span>
              </li>
            ))}
          </ul>
        )
      )}

      {tab === "paid" && (
        paid.length === 0 ? <Empty>{EMPTY.paid}</Empty> : (
          <ul className="m-card divide-y divide-line overflow-hidden">
            {paid.map((p) => (
              <li key={p.id} className="px-4 py-3">
                <div className="flex items-start justify-between gap-3">
                  <span className="min-w-0">
                    <span className="m-body block text-ink">{p.item}</span>
                    <span className="m-micro block text-ink-3">{date(p.at)}</span>
                  </span>
                  <span className="num shrink-0 text-[15px] text-ink">{formatMoney(p.amount_cents, p.currency)}</span>
                </div>
                <a href={`/receipts/${p.id}.pdf`} className="m-sub m-press mt-1.5 inline-block"
                   style={{ color: "var(--lime-text)" }}>Download receipt</a>
              </li>
            ))}
          </ul>
        )
      )}

      {tab === "refunded" && (
        refunded.length === 0 ? <Empty>{EMPTY.refunded}</Empty> : (
          <ul className="m-card divide-y divide-line overflow-hidden">
            {refunded.map((p) => (
              <li key={p.id} className="px-4 py-3">
                <div className="flex items-start justify-between gap-3">
                  <span className="min-w-0">
                    <span className="m-body block text-ink">{p.item}</span>
                    <span className="m-micro block text-ink-3">
                      {date(p.refunded_at ?? p.at)} · {formatMoney(p.refunded_cents, p.currency)} refunded
                    </span>
                  </span>
                  <span className="num shrink-0 text-[15px] text-ink-3 line-through">{formatMoney(p.amount_cents, p.currency)}</span>
                </div>
                <a href={`/receipts/${p.id}.pdf`} className="m-sub m-press mt-1.5 inline-block"
                   style={{ color: "var(--lime-text)" }}>Download receipt</a>
              </li>
            ))}
          </ul>
        )
      )}

      {tab === "desk" && (
        desk.length === 0 ? <Empty>{EMPTY.desk}</Empty> : (
          <ul className="m-card divide-y divide-line overflow-hidden">
            {desk.map((b) => (
              <li key={b.booking_id} className="flex items-start justify-between gap-3 px-4 py-3">
                <span className="min-w-0">
                  <span className="m-body block text-ink">{b.item}</span>
                  <span className="m-micro block text-ink-3">{date(b.starts_at)} · {fmtClock(b.starts_at, ctx.timeZone, fmt)}</span>
                </span>
                <span className="shrink-0 text-right">
                  {b.due_cents != null && (
                    <span className="num block text-[15px] text-ink">{formatMoney(b.due_cents, b.currency)}</span>
                  )}
                  <Chip>Pay at the desk</Chip>
                </span>
              </li>
            ))}
          </ul>
        )
      )}
    </MemberShell>
  );
}

function Empty({ children }: { children: React.ReactNode }) {
  return (
    <div className="m-card p-5 text-center">
      <p className="m-body text-ink">{children}</p>
    </div>
  );
}
