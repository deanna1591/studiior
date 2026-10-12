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
