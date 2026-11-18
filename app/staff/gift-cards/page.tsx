import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { formatMoney } from "@/lib/plans";
import { dayMonthParts } from "@/lib/time";
import { AppShell, Denied, Empty } from "@/components/ui";
import GiftRowActions from "./row-actions";

export const dynamic = "force-dynamic";

const STATUS: Record<string, { label: string; tone: string }> = {
  active:   { label: "Unclaimed", tone: "var(--ink-2)" },
  redeemed: { label: "Claimed",   tone: "var(--lime-text)" },
  void:     { label: "Voided",    tone: "var(--ink-3)" },
};

/**
 * Decision 110: the studio's gift cards — code, amount, buyer, recipient,
 * status, with resend (active) and void (manager-up). Gift credit never expires.
 */
export default async function GiftCards() {
  const screen = await staffScreen();
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Gift cards"><Denied what="gift cards" role={ctx.role} /></AppShell>;
  }

  const { data: rows } = await supabase
    .from("gift_cards")
    .select("id, code, amount_cents, currency, status, buyer_name, buyer_email, recipient_name, recipient_email, created_at, redeemed_at")
    .eq("studio_id", ctx.studioId)
    .in("status", ["active", "redeemed", "void"])
    .order("created_at", { ascending: false });

  const cards = rows ?? [];

  return (
    <AppShell {...shell} title="Gift cards">
      <h1 className="text-head mb-1">Gift cards</h1>
      <p className="text-sub mb-5 text-ink-2">
        Every gift card bought for the studio. Gift credit never expires. Voiding stops an
        unclaimed card.
      </p>

      {cards.length === 0 ? (
        <Empty>No gift cards yet. The public page is at your member site under /gift.</Empty>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full min-w-[640px] text-left text-[14px]">
            <thead>
              <tr className="border-b border-line text-[12px] uppercase tracking-wide text-ink-3">
                <th className="py-2 pr-3 font-medium">Code</th>
                <th className="py-2 pr-3 font-medium">Amount</th>
                <th className="py-2 pr-3 font-medium">Buyer</th>
                <th className="py-2 pr-3 font-medium">Recipient</th>
                <th className="py-2 pr-3 font-medium">Status</th>
                <th className="py-2 pr-3 font-medium"></th>
              </tr>
            </thead>
            <tbody>
              {cards.map((c) => {
                const st = STATUS[c.status] ?? { label: c.status, tone: "var(--ink-3)" };
                const d = dayMonthParts(c.created_at, ctx.timeZone);
                return (
                  <tr key={c.id} className="border-b border-line align-top">
                    <td className="py-2.5 pr-3 num font-semibold text-ink">{c.code ?? "—"}</td>
                    <td className="py-2.5 pr-3 num text-ink">{formatMoney(c.amount_cents ?? 0, c.currency ?? "PHP")}</td>
                    <td className="py-2.5 pr-3 text-ink-2">
                      <span className="block text-ink">{c.buyer_name ?? "—"}</span>
                      <span className="block text-[12px] text-ink-3">{c.buyer_email}</span>
                      <span className="block text-[12px] text-ink-3">{d.day} {d.month}</span>
                    </td>
                    <td className="py-2.5 pr-3 text-ink-2">
                      <span className="block text-ink">{c.recipient_name ?? "—"}</span>
                      <span className="block text-[12px] text-ink-3">{c.recipient_email}</span>
                    </td>
                    <td className="py-2.5 pr-3 font-medium" style={{ color: st.tone }}>{st.label}</td>
                    <td className="py-2.5 pr-3">
                      {c.status === "active" && <GiftRowActions id={c.id} />}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </AppShell>
  );
}
