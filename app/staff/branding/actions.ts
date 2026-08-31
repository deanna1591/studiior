"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";
import { isHex, PRESET_KEYS, type PresetKey } from "@/lib/theme";

export type BrandingState = { ok: boolean; message: string } | null;

/**
 * Save the member app's look.
 *
 * Owner only — enforced by studios_owner_brand, not by this file. What this
 * does check is shape: an accent that is not six hex digits would fail the
 * column constraint with a message about a check violation, and "that is not a
 * colour" is more use than that.
 */
export async function saveBranding(_prev: BrandingState, fd: FormData): Promise<BrandingState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const preset = String(fd.get("theme_preset") ?? "warm") as PresetKey;
  if (!PRESET_KEYS.includes(preset)) return { ok: false, message: "Pick one of the four looks." };

  const rawAccent = String(fd.get("accent_color") ?? "").trim().toUpperCase();
  const accent = rawAccent === "" ? null : rawAccent;
  if (accent && !isHex(accent)) {
    return { ok: false, message: "An accent has to be a six-digit hex, like #BEF738." };
  }

  // Contact details. Not branding, strictly — but this is the only Owner-only
  // screen that governs what members see, and these two go out in the footer of
  // every email and set its reply-to. A member who replies to a booking
  // confirmation reaches this address or nobody.
  const rawEmail = String(fd.get("contact_email") ?? "").trim();
  const contactEmail = rawEmail === "" ? null : rawEmail;
  if (contactEmail && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(contactEmail)) {
    return { ok: false, message: "That does not look like an email address." };
  }
  const rawPhone = String(fd.get("contact_phone") ?? "").trim();
  const contactPhone = rawPhone === "" ? null : rawPhone;

  const supabase = createClient();
  const { data, error } = await supabase
    .from("studios")
    .update({ theme_preset: preset, accent_color: accent,
              contact_email: contactEmail, contact_phone: contactPhone })
    .eq("id", ctx.studioId)
    .select("id");

  if (error) return { ok: false, message: error.message };
  // RLS refuses an UPDATE by making the row invisible: PostgREST returns 200
  // and an empty array rather than an error (CLAUDE.md). Count the rows.
  if (!data || data.length === 0) {
    return { ok: false, message: "Only the studio owner can change how the member app looks." };
  }

  revalidatePath("/branding");
  return { ok: true, message: "Saved. Members will see it next time they open the app." };
}

/** Upload a logo into this studio's own folder in the branding bucket. */
export async function uploadLogo(_prev: BrandingState, fd: FormData): Promise<BrandingState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const file = fd.get("logo") as File | null;
  if (!file || file.size === 0) return { ok: false, message: "Choose an image first." };
  if (file.size > 2_000_000) return { ok: false, message: "That image is over 2 MB. A logo does not need to be." };
  if (!["image/png", "image/jpeg", "image/webp", "image/svg+xml"].includes(file.type)) {
    return { ok: false, message: "PNG, JPEG, WebP or SVG." };
  }

  const supabase = createClient();
  // The studio id is the first path segment, which is what the storage policy
  // checks — a session cannot write into another studio's folder.
  const ext = file.name.split(".").pop()?.toLowerCase() ?? "png";
  const path = `${ctx.studioId}/logo-${Date.now()}.${ext}`;

  const { error } = await supabase.storage
    .from("studio-branding")
    .upload(path, file, { cacheControl: "3600", upsert: false });
  if (error) {
    return /row-level security|Unauthorized/i.test(error.message)
      ? { ok: false, message: "Only the studio owner can change the logo." }
      : { ok: false, message: error.message };
  }

  const { data: pub } = supabase.storage.from("studio-branding").getPublicUrl(path);
  const { data: rows, error: upErr } = await supabase
    .from("studios").update({ logo_url: pub.publicUrl }).eq("id", ctx.studioId).select("id");
  if (upErr) return { ok: false, message: upErr.message };
  if (!rows || rows.length === 0) {
    return { ok: false, message: "The image uploaded but the studio record could not be updated." };
  }

  revalidatePath("/branding");
  return { ok: true, message: "Logo updated." };
}

/**
 * The login screen's photograph.
 *
 * login_image_url has been on studios since migration 029 and nothing has ever
 * written to it, so every studio fell through to the accent gradient and the
 * frosted panel built for a photograph never rendered anywhere.
 *
 * Same path as the logo, and the same storage policy does the enforcing: the
 * studio id is the first path segment and "owners write their own studio's
 * branding" checks it, so a session cannot write into another studio's folder
 * whatever this function does.
 *
 * The 2 MB ceiling is the bucket's own (migration 029 sets file_size_limit),
 * not a number invented here — which is why it is worth saying out loud in the
 * copy rather than letting a wide studio photograph fail with a raw storage
 * error the owner cannot act on.
 */
export async function uploadLoginImage(_prev: BrandingState, fd: FormData): Promise<BrandingState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const file = fd.get("login_image") as File | null;
  if (!file || file.size === 0) return { ok: false, message: "Choose a photo first." };
  if (file.size > 2_000_000) {
    return {
      ok: false,
      message: "That photo is over 2 MB, which is the most this can store. "
             + "Exporting it at about 1600px wide usually gets well under.",
    };
  }
  if (!["image/png", "image/jpeg", "image/webp"].includes(file.type)) {
    // SVG is allowed in the bucket for the logo and is not a photograph.
    return { ok: false, message: "JPEG, PNG or WebP." };
  }

  const supabase = createClient();
  const ext = file.name.split(".").pop()?.toLowerCase() ?? "jpg";
  const path = `${ctx.studioId}/login-${Date.now()}.${ext}`;

  const { error } = await supabase.storage
    .from("studio-branding")
    .upload(path, file, { cacheControl: "3600", upsert: false });
  if (error) {
    return /row-level security|Unauthorized/i.test(error.message)
      ? { ok: false, message: "Only the studio owner can change the login photo." }
      : { ok: false, message: error.message };
  }

  const { data: pub } = supabase.storage.from("studio-branding").getPublicUrl(path);
  const { data: rows, error: upErr } = await supabase
    .from("studios").update({ login_image_url: pub.publicUrl }).eq("id", ctx.studioId).select("id");
  if (upErr) return { ok: false, message: upErr.message };
  if (!rows || rows.length === 0) {
    return { ok: false, message: "The photo uploaded but the studio record could not be updated." };
  }

  revalidatePath("/branding");
  return { ok: true, message: "Login photo updated. Members see it before they sign in." };
}
