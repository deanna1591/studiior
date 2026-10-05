import { notFound } from "next/navigation";
import { AppShell, Denied, NavLink, SectionLabel } from "@/components/ui";
import { staffScreen } from "@/lib/screen";
import { isManagerUp } from "@/lib/auth";
import { fromCents } from "@/lib/plans";
import PhotoUpload from "@/components/instructor/photo-upload";
import ProductForm from "../product-form";
import { StockForm, ArchiveButton } from "../forms";
import { uploadProductPhoto, removeProductPhoto } from "../actions";

export const dynamic = "force-dynamic";

export default async function EditProduct({ params }: { params: { id: string } }) {
  const screen = await staffScreen("/shop");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Shop"><Denied what="Editing products" role={ctx.role} /></AppShell>;
  }
  const { data: p } = await supabase.from("products")
    .select("id, name, description, photo_url, price_cents, track_stock, stock, low_stock_threshold, status, sort_order")
    .eq("id", params.id).eq("studio_id", ctx.studioId).maybeSingle();
  if (!p) notFound();

  return (
    <AppShell {...shell} title={p.name} actions={<NavLink href="/shop">Back to shop</NavLink>}>
      <p className="mb-5 text-[13px] text-ink-2">{p.status === "archived" ? "Archived — not on sale" : "On sale"}</p>

      <div className="mb-6 max-w-md">
        <SectionLabel>Photo</SectionLabel>
        <div className="mt-2">
          <PhotoUpload variant="staff" name={p.name} currentUrl={p.photo_url}
            upload={async (fd) => { "use server"; return uploadProductPhoto(p.id, fd); }}
            remove={async () => { "use server"; return removeProductPhoto(p.id); }} />
        </div>
      </div>

      <ProductForm mode="edit" currency={ctx.currency}
        draft={{ id: p.id, name: p.name, description: p.description, price: fromCents(p.price_cents),
                 track_stock: p.track_stock, stock: p.stock, low_stock_threshold: p.low_stock_threshold,
                 sort_order: p.sort_order }} />

      {p.track_stock && (
        <div className="mt-8 max-w-md">
          <SectionLabel>Stock</SectionLabel>
          <p className="mb-2 mt-1 text-[13px] text-ink-2"><span className="num">{p.stock}</span> on hand.</p>
          <StockForm productId={p.id} />
        </div>
      )}

      <div className="mt-8">
        <ArchiveButton id={p.id} archived={p.status === "archived"} />
      </div>
    </AppShell>
  );
}
