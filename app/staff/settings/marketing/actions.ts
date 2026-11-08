"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext, isDeskUp } from "@/lib/auth";
import { isValidSpec, type BrandSpec } from "@/lib/brand-kit";
import type { PostData } from "@/lib/schedule-post";
import type { Json } from "@/lib/database.types";

const BUCKET = "brand-references";
const OK_MIME = ["image/png", "image/jpeg", "image/jpg", "application/pdf"];
const MAX = 10_485_760;

export type BrandRef = { name: string; url: string };

function managerUp(role: string): boolean {
  return role === "owner" || role === "manager";
}

/** The references on file, with short-lived signed URLs for thumbnails. */
export async function listBrandReferences(): Promise<BrandRef[]> {
  const ctx = await getStaffContext();
  if (!ctx || !managerUp(ctx.role)) return [];
  const supabase = createClient();
  const { data } = await supabase.storage.from(BUCKET).list(ctx.studioId, {
    limit: 20, sortBy: { column: "name", order: "asc" },
  });
  const files = (data ?? []).filter((f) => f.name && f.id).slice(0, 5);
  const out: BrandRef[] = [];
  for (const f of files) {
    const { data: signed } = await supabase.storage.from(BUCKET)
      .createSignedUrl(`${ctx.studioId}/${f.name}`, 3600);
    out.push({ name: f.name, url: signed?.signedUrl ?? "" });
  }
  return out;
}

export async function uploadBrandReference(fd: FormData): Promise<{ ok?: true; error?: string; refs?: BrandRef[] }> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };
  if (!managerUp(ctx.role)) return { error: "Only owners and managers manage the brand kit." };

  const file = fd.get("file") as File | null;
  if (!file || file.size === 0) return { error: "Choose a file first." };
  if (file.size > MAX) return { error: "That file is over 10 MB." };
  if (!OK_MIME.includes(file.type)) return { error: "PNG, JPG or PDF." };

  const supabase = createClient();
  const existing = await listBrandReferences();
  if (existing.length >= 5) return { error: "Up to five references. Remove one first." };

  const ext = file.name.split(".").pop()?.toLowerCase() ?? "png";
  const path = `${ctx.studioId}/ref-${Date.now()}.${ext}`;
  const { error } = await supabase.storage.from(BUCKET).upload(path, file, { upsert: false });
  if (error) {
    return /row-level security|Unauthorized/i.test(error.message)
      ? { error: "Your role cannot upload references." }
      : { error: error.message };
  }
  revalidatePath("/settings/marketing/brand-kit");
  return { ok: true, refs: await listBrandReferences() };
}

export async function removeBrandReference(name: string): Promise<{ ok?: true; error?: string; refs?: BrandRef[] }> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };
  if (!managerUp(ctx.role)) return { error: "Only owners and managers manage the brand kit." };
  if (!/^[\w.-]+$/.test(name)) return { error: "That file name isn't valid." };

  const supabase = createClient();
  const { error } = await supabase.storage.from(BUCKET).remove([`${ctx.studioId}/${name}`]);
  if (error) return { error: error.message };
  revalidatePath("/settings/marketing/brand-kit");
  return { ok: true, refs: await listBrandReferences() };
}

/** Save a hand-overridden spec (source 'manual'). */
export async function saveBrandKit(spec: BrandSpec): Promise<{ ok?: true; error?: string }> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };
  if (!managerUp(ctx.role)) return { error: "Only owners and managers manage the brand kit." };
  if (!isValidSpec(spec)) return { error: "That brand spec isn't valid." };

  const supabase = createClient();
  const { error } = await supabase.rpc("brand_kit_save", {
    p_studio_id: ctx.studioId, p_spec: spec as unknown as Json, p_source: "manual",
  });
  if (error) {
    return /PT403|manager|owner/i.test(error.message)
      ? { error: "Only owners and managers manage the brand kit." }
      : { error: error.message };
  }
  revalidatePath("/settings/marketing/brand-kit");
  return { ok: true };
}

/** Reset to the studio defaults (source 'default'). */
export async function resetBrandKit(): Promise<{ ok?: true; error?: string }> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };
  if (!managerUp(ctx.role)) return { error: "Only owners and managers manage the brand kit." };

  const supabase = createClient();
  const { data: cur } = await supabase.rpc("brand_kit_current", { p_studio_id: ctx.studioId });
  const defaults = (cur as { defaults?: BrandSpec } | null)?.defaults;
  if (!defaults) return { error: "Could not read the studio defaults." };
  const { error } = await supabase.rpc("brand_kit_save", {
    p_studio_id: ctx.studioId, p_spec: defaults as unknown as Json, p_source: "default",
  });
  if (error) return { error: error.message };
  revalidatePath("/settings/marketing/brand-kit");
  return { ok: true };
}

// --- Schedule posts (Decision 93 slice 2) -----------------------------------

const POST_BUCKET = "post-images";

/** The visible scheduled classes in a range, grouped by day, in the studio's
 *  look — one desk-up call. core_only=false: every class comes back with its
 *  tier so the UI toggles core-only instantly client-side. */
export async function schedulePostData(from: string, to: string): Promise<{ data?: PostData; error?: string }> {
  const ctx = await getStaffContext();
  if (!ctx || !isDeskUp(ctx.role)) return { error: "Only the studio team can make posts." };
  if (!/^\d{4}-\d{2}-\d{2}$/.test(from) || !/^\d{4}-\d{2}-\d{2}$/.test(to)) return { error: "Bad dates." };
  const supabase = createClient();
  const { data, error } = await supabase.rpc("schedule_post_data", {
    p_studio_id: ctx.studioId, p_from: from, p_to: to, p_core_only: false,
  });
  if (error) {
    return /PT403|team|owner|manager/i.test(error.message)
      ? { error: "Only the studio team can make posts." }
      : { error: error.message };
  }
  return { data: data as unknown as PostData };
}

/** Save the footer line + hashtags that go on posts (manager-up, via the
 *  studio_settings RLS). */
export async function savePostSettings(fd: FormData): Promise<{ ok?: true; error?: string }> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };
  if (!managerUp(ctx.role)) return { error: "Only owners and managers change post settings." };
  const footer = String(fd.get("footer") ?? "").trim().slice(0, 120) || "Book on the app";
  const hashtags = String(fd.get("hashtags") ?? "").trim().slice(0, 300) || null;
  const supabase = createClient();
  const { error, count } = await supabase.from("studio_settings")
    .update({ post_footer_line: footer, post_hashtags: hashtags }, { count: "exact" })
    .eq("studio_id", ctx.studioId);
  if (error) return { error: error.message };
  if (!count) return { error: "Only owners and managers change post settings." };
  revalidatePath("/settings/marketing");
  return { ok: true };
}

/** Upload an exported post PNG to post-images under {studio}/{yyyy-mm}/{file}
 *  (desk-up storage policy). Part (b) posts these; here it is the saved copy. */
export async function uploadPostImage(fd: FormData): Promise<{ ok?: true; path?: string; error?: string }> {
  const ctx = await getStaffContext();
  if (!ctx || !isDeskUp(ctx.role)) return { error: "Only the studio team can make posts." };
  const file = fd.get("file") as File | null;
  if (!file || file.size === 0) return { error: "Nothing to upload." };
  if (file.type !== "image/png") return { error: "PNG only." };
  if (file.size > 5_242_880) return { error: "That image is over 5 MB." };
  const supabase = createClient();
  const yyyymm = new Date().toISOString().slice(0, 7); // uploaded-month folder
  const path = `${ctx.studioId}/${yyyymm}/post-${Date.now()}.png`;
  const { error } = await supabase.storage.from(POST_BUCKET).upload(path, file, {
    upsert: false, contentType: "image/png",
  });
  if (error) {
    return /row-level security|Unauthorized/i.test(error.message)
      ? { error: "Your role cannot save posts." }
      : { error: error.message };
  }
  return { ok: true, path };
}

/** A short-lived signed URL for a post-images object in the caller's own studio
 *  (the bucket is private), so the renderer can inline a Claude-edit background
 *  photo for the preview and the PNG export. Desk-up. */
export async function signPostImage(path: string): Promise<{ url?: string; error?: string }> {
  const ctx = await getStaffContext();
  if (!ctx || !isDeskUp(ctx.role)) return { error: "Only the studio team can make posts." };
  if (!path.startsWith(`${ctx.studioId}/`)) return { error: "That image isn't yours." };
  const supabase = createClient();
  const { data, error } = await supabase.storage.from(POST_BUCKET).createSignedUrl(path, 3600);
  if (error || !data?.signedUrl) return { error: "Could not load the photo." };
  return { url: data.signedUrl };
}
