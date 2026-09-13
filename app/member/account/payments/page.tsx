import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import { formatMoney } from "@/lib/plans";
import { fmtDayLong } from "@/lib/time";

export const dynamic = "force-dynamic";

const METHOD: Record<string, string> = {
  cash: "Cash", bank_transfer: "Bank transfer", card_terminal: "Card at the desk",
  gcash: "GCash", other: "Other",
};

export default async function Payments() {
  const { ctx, supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } =
    await memberScreen();

  // payments_self RLS scopes this to the member's own rows.
  const { data } = await supabase
    .from("payments")
    .select("id, amount_cents, currency, status, description, method, card_brand, card_last4, paid_at, created_at")
    .eq("member_id", ctx.memberId)
    .order("created_at", { ascending: false })
    .limit(100);

  const rows = data ?? [];

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href="/account" className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Account
      </Link>
      <h1 className="m-title mb-4 text-ink">Payments</h1>

      {rows.length === 0 ? (
        <div className="m-card p-5 text-center">
          <p className="m-body text-ink">Nothing yet.</p>
          <p className="m-sub mt-1 text-ink-2">What you pay shows up here.</p>
        </div>
      ) : (
        <ul className="m-card divide-y divide-line overflow-hidden">
          {rows.map((p) => {
            const how = p.card_brand && p.card_last4
              ? `${p.card_brand} ·· ${p.card_last4}`
              : p.method ? METHOD[p.method] ?? p.method : null;
            const failed = p.status === "failed";
            const refunded = p.status === "refunded";
            return (
              <li key={p.id} className="flex items-start justify-between gap-3 px-4 py-3">
                <span className="min-w-0">
                  <span className="m-body block text-ink">{p.description ?? "Payment"}</span>
                  <span className="m-micro block text-ink-3">
                    {fmtDayLong(p.paid_at ?? p.created_at, ctx.timeZone)}{how ? ` · ${how}` : ""}
                    {failed ? " · didn’t go through" : refunded ? " · refunded" : ""}
                  </span>
                </span>
                <span className="num shrink-0 text-[15px]"
                      style={{ color: failed ? "var(--ink-3)" : "var(--ink)",
                               textDecoration: failed || refunded ? "line-through" : "none" }}>
                  {formatMoney(p.amount_cents, p.currency)}
                </span>
              </li>
            );
          })}
        </ul>
      )}
    </MemberShell>
  );
}
