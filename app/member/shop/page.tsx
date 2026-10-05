import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import { formatMoney } from "@/lib/plans";

export const dynamic = "force-dynamic";

type ShopItem = {
  id: string; name: string; description: string | null; photo_url: string | null;
  price_cents: number; currency: string; stock_left: number | null; sold_out: boolean;
};

export default async function Shop() {
  const { ctx, supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } =
    await memberScreen();
  const { data } = await supabase.rpc("member_shop", { p_studio_id: ctx.studioId });
  const items = (data ?? []) as ShopItem[];

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href="/account" className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Account
      </Link>
      <h1 className="m-title mb-1 text-ink">Shop</h1>
      <p className="m-sub mb-4 text-ink-2">Pick up and pay at the front desk.</p>

      {items.length === 0 ? (
        <div className="m-card p-5 text-center">
          <p className="m-body text-ink">Nothing in the shop right now.</p>
        </div>
      ) : (
        <ul className="space-y-3">
          {items.map((p) => (
            <li key={p.id} className="m-card flex gap-3 p-3">
              {p.photo_url
                // eslint-disable-next-line @next/next/no-img-element
                ? <img src={p.photo_url} alt="" className="h-16 w-16 shrink-0 rounded-xl object-cover" />
                : <span className="h-16 w-16 shrink-0 rounded-xl bg-paper" />}
              <div className="min-w-0 flex-1">
                <p className="text-[15px] font-semibold leading-5 text-ink">{p.name}</p>
                {p.description && <p className="m-sub mt-0.5 text-ink-2">{p.description}</p>}
                <p className="m-sub mt-1 text-ink-3">
                  <span className="num text-ink">{formatMoney(p.price_cents, p.currency)}</span>
                  {p.sold_out
                    ? <span className="ml-2 text-coral">Sold out</span>
                    : p.stock_left !== null
                      ? <span className="ml-2"><span className="num">{p.stock_left}</span> left</span>
                      : null}
                </p>
                <p className="m-micro mt-1 text-ink-3">Ask at the front desk.</p>
              </div>
            </li>
          ))}
        </ul>
      )}
    </MemberShell>
  );
}
