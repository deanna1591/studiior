"use server";

import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

export type EmailImageResult = { url?: string; error?: string };

/**
 * Decision 77 — upload an image for a composed email (campaign or closure
 * notice) into this studio's own folder in the EXISTING studio-branding bucket.
 * Same 2 MB ceiling and image types as a logo; path keyed on the studio id so
 * the bucket's RLS (manager-up, studio id = first path segment) is the boundary.
 * Returns the public URL the composer inserts as ![](url).
 */
export async function uploadEmailImage(fd: FormData): Promise<EmailImageResult> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };

  const file = fd.get("image") as File | null;
  if (!file || file.size === 0) return { error: "Choose an image first." };
  if (file.size > 2_000_000) return { error: "That image is over 2 MB." };
  if (!["image/png", "image/jpeg", "image/webp", "image/svg+xml"].includes(file.type)) {
    return { error: "PNG, JPEG, WebP or SVG." };
  }

  const supabase = createClient();
  const ext = file.name.split(".").pop()?.toLowerCase() ?? "png";
  const path = `${ctx.studioId}/email-${Date.now()}.${ext}`;
  const { error } = await supabase.storage
    .from("studio-branding")
    .upload(path, file, { cacheControl: "3600", upsert: false });
  if (error) {
    return /row-level security|Unauthorized/i.test(error.message)
      ? { error: "Your role cannot upload images." }
      : { error: error.message };
  }
  const { data: pub } = supabase.storage.from("studio-branding").getPublicUrl(path);
  return { url: pub.publicUrl };
}

export type EmailFrameChrome = {
  studioName: string;
  logoUrl: string | null;
  accent: string;        // the real hex, so the preview button shows the studio colour
  contact: string | null; // "email · phone · @handle"
  address: string | null;
};

/**
 * Decision 80a — the studio's email frame chrome, so the composer preview can
 * render the body INSIDE the real frame (header mark + accent rule + footer)
 * rather than a bare card. Fetched once by the composer. Reads the caller's own
 * studio; the default neutral accent matches render_notification's fallback.
 */
export async function emailFrameChrome(): Promise<EmailFrameChrome | null> {
  const ctx = await getStaffContext();
  if (!ctx) return null;
  const supabase = createClient();
  const [{ data: s }, { data: loc }] = await Promise.all([
    supabase.from("studios")
      .select("name, logo_url, accent_color, contact_email, contact_phone, instagram_handle")
      .eq("id", ctx.studioId).maybeSingle(),
    supabase.from("locations").select("address, is_primary, created_at")
      .eq("studio_id", ctx.studioId).eq("status", "active")
      .order("is_primary", { ascending: false }).order("created_at").limit(1).maybeSingle(),
  ]);
  if (!s) return null;
  const ig = (s.instagram_handle ?? "").trim();
  const contact = [s.contact_email, s.contact_phone, ig ? `@${ig}` : null]
    .filter(Boolean).join(" · ") || null;
  const a = (loc?.address ?? {}) as Record<string, string>;
  const address = [a.line1, a.line2, a.city, a.postal_code, a.country]
    .map((x) => (x ?? "").trim()).filter(Boolean).join(", ") || null;
  return {
    studioName: s.name,
    logoUrl: s.logo_url ?? null,
    accent: s.accent_color || "#78716C",
    contact,
    address,
  };
}
