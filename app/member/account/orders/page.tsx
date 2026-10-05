import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import { formatMoney } from "@/lib/plans";
import { dayMonthParts } from "@/lib/time";

export const dynamic = "force-dynamic";

type Order = {
  id: string; product_name: string; quantity: number;
  amount_cents: number; currency: string; status: string;
  created_at: string; collected_at: string | null;
};

const STATUS: Record<string, string> = {
  paid: "Paid — collect at the front desk",
  collected: "Collected",
  refunded: "Refunded",
};

export default async function MyOrders() {
  const { ctx, supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } =
    await memberScreen();
  const { data } = await supabase.rpc("member_orders");
  const orders = (data ?? []) as Order[];

  const d = (iso: string) => {
    const { day, month } = dayMonthParts(iso, ctx.timeZone);
    return `${day} ${month}`;
  };

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href="/account" className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Account
      </Link>
      <h1 className="m-title mb-4 text-ink">My orders</h1>

      {orders.length === 0 ? (
        <div className="m-card p-5 text-center">
          <p className="m-body text-ink">No orders yet.</p>
          <p className="m-sub mt-1 text-ink-2">
            <Link href="/shop" className="text-lime-text underline underline-offset-4">Visit the shop</Link>.
          </p>
        </div>
      ) : (
        <ul className="space-y-3">
          {orders.map((o) => (
            <li key={o.id} className="m-card p-4">
              <div className="flex items-baseline justify-between gap-3">
                <p className="text-[15px] font-semibold leading-5 text-ink">
                  {o.product_name} <span className="num text-ink-2">×{o.quantity}</span>
                </p>
                <span className="num shrink-0 text-[14px] text-ink">{formatMoney(o.amount_cents, o.currency)}</span>
              </div>
              <p className="m-sub mt-1 text-ink-2">{STATUS[o.status] ?? o.status}</p>
              <p className="m-micro mt-0.5 text-ink-3">Ordered {d(o.created_at)}{o.collected_at ? ` · collected ${d(o.collected_at)}` : ""}</p>
            </li>
          ))}
        </ul>
      )}
    </MemberShell>
  );
}
