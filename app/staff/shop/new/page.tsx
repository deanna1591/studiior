import { AppShell, Denied, NavLink } from "@/components/ui";
import { staffScreen } from "@/lib/screen";
import { isManagerUp } from "@/lib/auth";
import ProductForm from "../product-form";

export const dynamic = "force-dynamic";

export default async function NewProduct() {
  const screen = await staffScreen("/shop");
  if (screen.gate) return screen.gate;
  const { ctx, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Shop"><Denied what="Adding products" role={ctx.role} /></AppShell>;
  }
  return (
    <AppShell {...shell} title="New product" actions={<NavLink href="/shop">Back to shop</NavLink>}>
      <p className="mb-4 text-[13px] text-ink-2">Add the photo after you save — it uploads from the product&rsquo;s page.</p>
      <ProductForm mode="new" currency={ctx.currency}
        draft={{ name: "", description: null, price: "", track_stock: true, stock: 0, low_stock_threshold: null, sort_order: 0 }} />
    </AppShell>
  );
}
