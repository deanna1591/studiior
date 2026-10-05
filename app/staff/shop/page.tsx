import Link from "next/link";
import { AppShell, Empty, NavLink, SectionLabel } from "@/components/ui";
import { staffScreen } from "@/lib/screen";
import { isManagerUp } from "@/lib/auth";
import { formatMoney } from "@/lib/plans";
import { RecordSaleForm, CollectButton, ArchiveButton } from "./forms";

export const dynamic = "force-dynamic";

export default async function Shop() {
  const screen = await staffScreen("/shop");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  const manager = isManagerUp(ctx.role);

  const [{ data: products }, { data: toCollect }, { data: members }] = await Promise.all([
    supabase.from("products").select("id, name, price_cents, currency, track_stock, stock, low_stock_threshold, status, photo_url")
      .eq("studio_id", ctx.studioId).order("status").order("sort_order").order("name"),
    supabase.from("product_orders")
      .select("id, quantity, created_at, products(name), members(first_name, last_name)")
      .eq("studio_id", ctx.studioId).eq("status", "paid").order("created_at"),
    supabase.from("members").select("id, first_name, last_name")
      .eq("studio_id", ctx.studioId).eq("status", "active").order("first_name").limit(500),
  ]);

  const list = (products ?? []) as {
    id: string; name: string; price_cents: number; currency: string;
    track_stock: boolean; stock: number; low_stock_threshold: number | null; status: string; photo_url: string | null;
  }[];
  const active = list.filter((p) => p.status === "active");
  const archived = list.filter((p) => p.status !== "active");
  const saleProducts = active.map((p) => ({ id: p.id, name: p.name, price_cents: p.price_cents, track_stock: p.track_stock, stock: p.stock }));
  const memberOpts = ((members ?? []) as { id: string; first_name: string; last_name: string }[])
    .map((m) => ({ id: m.id, name: `${m.first_name} ${m.last_name}`.trim() }));
  const collect = (toCollect ?? []) as {
    id: string; quantity: number; created_at: string;
    products: { name: string } | null; members: { first_name: string; last_name: string } | null;
  }[];

  return (
    <AppShell {...shell} title="Shop"
      actions={manager ? <NavLink href="/shop/new">New product</NavLink> : undefined}>
      {/* To collect — paid in-app orders waiting for pickup. */}
      {collect.length > 0 && (
        <section className="mb-8">
          <SectionLabel>To collect</SectionLabel>
          <ul className="mt-2 divide-y divide-line rounded border border-line">
            {collect.map((o) => (
              <li key={o.id} className="flex items-center justify-between gap-3 px-3 py-2.5">
                <span className="text-[14px] text-ink">
                  {o.products?.name ?? "Product"} <span className="num">×{o.quantity}</span>
                  {o.members ? <span className="text-ink-3"> · {o.members.first_name} {o.members.last_name}</span> : null}
                </span>
                <CollectButton orderId={o.id} />
              </li>
            ))}
          </ul>
        </section>
      )}

      {/* Record a sale — desk-up. */}
      <section className="mb-8">
        <SectionLabel>Record a sale</SectionLabel>
        <div className="mt-3"><RecordSaleForm products={saleProducts} members={memberOpts} currency={ctx.currency} /></div>
      </section>

      {/* Products. */}
      <section>
        <SectionLabel>Products</SectionLabel>
        {active.length === 0 ? (
          <Empty>No products yet.{manager ? " Add one to start selling." : ""}</Empty>
        ) : (
          <ul className="mt-2 divide-y divide-line rounded border border-line">
            {active.map((p) => (
              <li key={p.id} className="flex items-center gap-3 px-3 py-2.5">
                {p.photo_url
                  // eslint-disable-next-line @next/next/no-img-element
                  ? <img src={p.photo_url} alt="" className="h-10 w-10 shrink-0 rounded object-cover" />
                  : <span className="h-10 w-10 shrink-0 rounded bg-paper" />}
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-[14px] font-medium text-ink">
                    {manager ? <Link href={`/shop/${p.id}`} className="hover:underline">{p.name}</Link> : p.name}
                  </span>
                  <span className="block text-[12px] text-ink-3">
                    <span className="num">{formatMoney(p.price_cents, p.currency)}</span>
                    {p.track_stock
                      ? <> · <span className="num">{p.stock}</span> in stock
                          {p.low_stock_threshold != null && p.stock <= p.low_stock_threshold
                            ? <span className="ml-1 rounded border-l-2 border-coral bg-coral-tint px-1.5 text-ink">low</span> : null}</>
                      : " · not tracked"}
                  </span>
                </span>
                {manager && <ArchiveButton id={p.id} archived={false} />}
              </li>
            ))}
          </ul>
        )}
        {manager && archived.length > 0 && (
          <div className="mt-4">
            <SectionLabel>Archived</SectionLabel>
            <ul className="mt-2 divide-y divide-line rounded border border-line">
              {archived.map((p) => (
                <li key={p.id} className="flex items-center justify-between gap-3 px-3 py-2.5">
                  <span className="text-[14px] text-ink-2">{p.name}</span>
                  <ArchiveButton id={p.id} archived={true} />
                </li>
              ))}
            </ul>
          </div>
        )}
      </section>
    </AppShell>
  );
}
