"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";
import type { PhotoResult } from "@/components/instructor/photo-upload";
import { toCents } from "@/lib/plans";

export type ShopState = { error: string } | { ok: string } | null;

const BUCKET = "product-photos";
function pathInBucket(url: string | null): string | null {
  if (!url) return null;
  const m = url.match(/\/product-photos\/(.+)$/);
  return m ? m[1] : null;
}

/** Create or update a product. Manager-up (RLS on products). */
export async function saveProduct(_prev: ShopState, fd: FormData): Promise<ShopState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };
  const supabase = createClient();

  const id = String(fd.get("id") ?? "").trim() || null;
  const name = String(fd.get("name") ?? "").trim();
  if (!name) return { error: "A name is needed." };
  const price = toCents(String(fd.get("price") ?? ""));
  if (price === null) return { error: "A price like 150 or 150.00." };
  const track = fd.get("track_stock") === "1";
  const stock = track ? Math.max(0, parseInt(String(fd.get("stock") ?? "0"), 10) || 0) : 0;
  const lowRaw = String(fd.get("low_stock_threshold") ?? "").trim();
  const low = track && lowRaw !== "" ? Math.max(0, parseInt(lowRaw, 10) || 0) : null;
  const sort = parseInt(String(fd.get("sort_order") ?? "0"), 10) || 0;
  const description = String(fd.get("description") ?? "").trim() || null;

  const row = {
    name, description, price_cents: price, currency: ctx.currency,
    track_stock: track, stock, low_stock_threshold: low, sort_order: sort,
  };

  if (id) {
    const { error, data } = await supabase.from("products").update(row)
      .eq("id", id).eq("studio_id", ctx.studioId).select("id");
    if (error) return { error: error.message };
    if (!data?.length) return { error: "You cannot edit this product." };
    revalidatePath(`/shop/${id}`); revalidatePath("/shop");
    return { ok: "Saved." };
  }
  const { data, error } = await supabase.from("products")
    .insert({ ...row, studio_id: ctx.studioId }).select("id").maybeSingle();
  if (error) return { error: error.message };
  revalidatePath("/shop");
  return { ok: `Added ${name}.${data?.id ? ` id:${data.id}` : ""}` };
}

/** Archive / restore a product. Manager-up. */
export async function setProductStatus(_prev: ShopState, fd: FormData): Promise<ShopState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };
  const id = String(fd.get("id"));
  const status = fd.get("status") === "archived" ? "archived" : "active";
  const supabase = createClient();
  const { error, data } = await supabase.from("products").update({ status })
    .eq("id", id).eq("studio_id", ctx.studioId).select("id");
  if (error) return { error: error.message };
  if (!data?.length) return { error: "You cannot change this product." };
  revalidatePath("/shop"); revalidatePath(`/shop/${id}`);
  return { ok: status === "archived" ? "Archived." : "Back on sale." };
}

/** Record a desk sale. Desk-up (the RPC enforces it). */
export async function recordSale(_prev: ShopState, fd: FormData): Promise<ShopState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };
  const supabase = createClient();
  const { data, error } = await supabase.rpc("record_product_sale", {
    p_studio_id: ctx.studioId,
    p_product_id: String(fd.get("product_id")),
    p_quantity: Math.max(1, parseInt(String(fd.get("quantity") ?? "1"), 10) || 1),
    p_member_id: String(fd.get("member_id") ?? "").trim() || undefined,
    p_method: String(fd.get("method") ?? "cash"),
    p_method_note: String(fd.get("method_note") ?? "").trim() || undefined,
  });
  if (error) return { error: error.message };
  void data;
  revalidatePath("/shop");
  return { ok: "Sale recorded." };
}

/** Adjust stock (restock / adjust). Manager-up (the RPC enforces it). */
export async function adjustStock(_prev: ShopState, fd: FormData): Promise<ShopState> {
  const supabase = createClient();
  const delta = parseInt(String(fd.get("delta") ?? "0"), 10) || 0;
  const { error } = await supabase.rpc("adjust_stock", {
    p_product_id: String(fd.get("product_id")),
    p_delta: delta,
    p_reason: String(fd.get("reason") ?? "restock"),
    p_note: String(fd.get("note") ?? "").trim() || undefined,
  });
  if (error) return { error: error.message };
  revalidatePath(`/shop/${String(fd.get("product_id"))}`); revalidatePath("/shop");
  return { ok: "Stock updated." };
}

/** Mark an in-app order collected. Desk-up (the RPC enforces it). */
export async function markCollected(_prev: ShopState, fd: FormData): Promise<ShopState> {
  const supabase = createClient();
  const { error } = await supabase.rpc("mark_order_collected", { p_order_id: String(fd.get("order_id")) });
  if (error) return { error: error.message };
  revalidatePath("/shop");
  return { ok: "Collected." };
}

/** Upload a product photo (Decision 60 pattern). */
export async function uploadProductPhoto(productId: string, fd: FormData): Promise<PhotoResult> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "Not signed in." };
  const file = fd.get("photo") as File | null;
  if (!file || file.size === 0) return { ok: false, message: "Choose a photo first." };
  if (file.size > 2_000_000) return { ok: false, message: "That photo is too large after shrinking — try another." };
  if (!["image/png", "image/jpeg", "image/webp"].includes(file.type)) return { ok: false, message: "JPEG, PNG or WebP." };

  const supabase = createClient();
  const { data: prod } = await supabase.from("products")
    .select("id, photo_url").eq("id", productId).eq("studio_id", ctx.studioId).maybeSingle();
  if (!prod) return { ok: false, message: "That product is not in this studio." };

  const ext = file.type === "image/png" ? "png" : file.type === "image/webp" ? "webp" : "jpg";
  const path = `${ctx.studioId}/${productId}/${Date.now()}.${ext}`;
  const up = await supabase.storage.from(BUCKET).upload(path, file, { cacheControl: "3600", upsert: false });
  if (up.error) {
    return /row-level security|Unauthorized|denied/i.test(up.error.message)
      ? { ok: false, message: "You cannot set this product's photo." }
      : { ok: false, message: up.error.message };
  }
  const { data: pub } = supabase.storage.from(BUCKET).getPublicUrl(path);
  const { data, error } = await supabase.from("products").update({ photo_url: pub.publicUrl }).eq("id", productId).select("id");
  if (error) return { ok: false, message: error.message };
  if (!data?.length) return { ok: false, message: "The photo uploaded but the product could not be updated." };
  const old = pathInBucket(prod.photo_url);
  if (old && old !== path) await supabase.storage.from(BUCKET).remove([old]);
  revalidatePath(`/shop/${productId}`); revalidatePath("/shop");
  return { ok: true, message: "Photo updated." };
}

export async function removeProductPhoto(productId: string): Promise<PhotoResult> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "Not signed in." };
  const supabase = createClient();
  const { data: prod } = await supabase.from("products")
    .select("id, photo_url").eq("id", productId).eq("studio_id", ctx.studioId).maybeSingle();
  if (!prod) return { ok: false, message: "That product is not in this studio." };
  const { data, error } = await supabase.from("products").update({ photo_url: null }).eq("id", productId).select("id");
  if (error) return { ok: false, message: error.message };
  if (!data?.length) return { ok: false, message: "You cannot change this product's photo." };
  const old = pathInBucket(prod.photo_url);
  if (old) await supabase.storage.from(BUCKET).remove([old]);
  revalidatePath(`/shop/${productId}`); revalidatePath("/shop");
  return { ok: true, message: "Photo removed." };
}
