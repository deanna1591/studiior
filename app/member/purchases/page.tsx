import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import { dayMonthLongParts } from "@/lib/time";
import { membershipTab, membershipChip, usedOfTotal } from "@/lib/wallet";

export const dynamic = "force-dynamic";

const TABS = [
  { key: "subscriptions", label: "Subscriptions" },
  { key: "passes", label: "Passes" },
] as const;
type TabKey = (typeof TABS)[number]["key"];

const EMPTY: Record<TabKey, string> = {
  subscriptions: "No subscriptions yet.",
  passes: "No passes yet.",
};

type Row = {
  id: string;
  status: string;
  credits_remaining: number | null;
  expires_on: string | null;
  renews_on: string | null;
  current_period_end: string | null;
  membership_plans: { name: string | null; type: string; credits: number | null } | null;
};

export default async function PurchasesScreen({
  searchParams,
}: { searchParams: { tab?: string } }) {
  const { ctx, supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } =
    await memberScreen();

  // memberships_self RLS scopes this; plans_member_own_membership lets the join
  // read the plan of a membership the member holds, whatever its visibility.
  const { data } = await supabase
    .from("memberships")
    .select("id, status, credits_remaining, expires_on, renews_on, current_period_end, membership_plans(name, type, credits)")
    .eq("member_id", ctx.memberId)
    .order("starts_on", { ascending: false });

  const rows = ((data ?? []) as unknown as Row[]);
  const subs = rows.filter((m) => membershipTab(m.membership_plans?.type ?? "") === "subscriptions");
  const passes = rows.filter((m) => membershipTab(m.membership_plans?.type ?? "") === "passes");

  const tab: TabKey = (TABS.some((t) => t.key === searchParams.tab) ? searchParams.tab : "subscriptions") as TabKey;
  const list = tab === "subscriptions" ? subs : passes;

  const date = (iso: string) => {
    const { day, month } = dayMonthLongParts(iso, ctx.timeZone);
    return `${day} ${month}`;
  };
  const validUntil = (m: Row) =>
    tab === "subscriptions"
      ? (m.expires_on ?? m.current_period_end ?? m.renews_on)
      : m.expires_on;

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent} title="Purchases">
      <Link href="/account" className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Account
      </Link>
      <h1 className="m-title mb-4 text-ink">Purchases</h1>

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

      {list.length === 0 ? (
        <div className="m-card p-5 text-center"><p className="m-body text-ink">{EMPTY[tab]}</p></div>
      ) : (
        <ul className="space-y-3">
          {list.map((m) => {
            const until = validUntil(m);
            const used = tab === "passes"
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
    </MemberShell>
  );
}
