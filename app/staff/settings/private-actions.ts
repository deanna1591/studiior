"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";
import { clampInt } from "@/lib/booking-rules";
import { objectPathFromPublicUrl } from "@/lib/storage";

export type PrivState = { ok: boolean; message: string } | null;

const IMMUTABLE_YEAR = "31536000, immutable";
const say = (m: string) => m.replace(/^.*?:\s*/, "");

/** Decision 116: the switch, the lead time and the buffer (manager-up via RLS). */
export async function savePrivateSettings(_p: PrivState, fd: FormData): Promise<PrivState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const on = String(fd.get("private_sessions_enabled") ?? "") === "on";
  const lead = Math.min(336, clampInt(fd.get("private_lead_time_hours"), 24));
  const buffer = Math.min(120, clampInt(fd.get("private_buffer_minutes"), 10));
  const replaceCore = Math.min(336, clampInt(fd.get("private_replace_core_hours"), 48));
  const supabase = createClient();
  const { data, error } = await supabase.from("studio_settings")
    .update({ private_sessions_enabled: on, private_lead_time_hours: lead, private_buffer_minutes: buffer,
              private_replace_core_hours: replaceCore })
    .eq("studio_id", ctx.studioId).select("studio_id");
  if (error) return { ok: false, message: error.message };
  if (!data?.length) return { ok: false, message: "Nothing was saved. Owners and managers only." };
  revalidatePath("/settings/memberships");
  return { ok: true, message: on ? "Private sessions are on. Members see them on Book." : "Private sessions are off." };
}

/** Create or edit one private session type (up to three active). */
export async function savePrivateType(_p: PrivState, fd: FormData): Promise<PrivState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const id = String(fd.get("id") ?? "") || null;
  const major = (k: string) => Math.round(Number(String(fd.get(k) ?? "").replace(/,/g, "")) * 100);
  const supabase = createClient();
  const { error } = await supabase.rpc("private_type_save", {
    p_studio_id: ctx.studioId, p_id: id as string,
    p_name: String(fd.get("name") ?? ""),
    p_price_cents: major("price"), p_people: Number(fd.get("people")),
    p_duration_min: Number(fd.get("duration_min")), p_coach_pay_cents: major("coach_pay"),
  });
  if (error) return { ok: false, message: say(error.message) };
  revalidatePath("/settings/memberships");
  return { ok: true, message: id ? "Saved." : "Added." };
}

export async function togglePrivateType(_p: PrivState, fd: FormData): Promise<PrivState> {
  const supabase = createClient();
  const { error } = await supabase.rpc("private_type_toggle", {
    p_id: String(fd.get("id")), p_active: String(fd.get("active")) === "true",
  });
  if (error) return { ok: false, message: say(error.message) };
  revalidatePath("/settings/memberships");
  return { ok: true, message: "Saved." };
}

/** Which coaches teach privates (instructors are manager-write under RLS). */
export async function saveTeachesPrivates(_p: PrivState, fd: FormData): Promise<PrivState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const on = new Set(fd.getAll("teaches").map(String));
  const supabase = createClient();
  const { data: all } = await supabase.from("instructors").select("id")
    .eq("studio_id", ctx.studioId).eq("status", "active");
  for (const i of all ?? []) {
    const { error } = await supabase.from("instructors")
      .update({ teaches_privates: on.has(i.id as string) }).eq("id", i.id as string);
    if (error) return { ok: false, message: error.message };
  }
  revalidatePath("/settings/memberships");
  return { ok: true, message: "Saved." };
}

/** Decision 110(a): the studio's gift card image (the brand-kit resizer runs in
 *  the browser first). Stored as a public studio-branding URL the card route draws on. */
export async function uploadGiftCardImage(_p: PrivState, fd: FormData): Promise<PrivState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const file = fd.get("gift_card_image") as File | null;
  if (!file || file.size === 0) return { ok: false, message: "Choose an image first." };
  if (file.size > 2_000_000) return { ok: false, message: "That image is over 2 MB." };
  if (!["image/png", "image/jpeg"].includes(file.type)) return { ok: false, message: "PNG or JPG." };
  const supabase = createClient();
  const { data: prev } = await supabase.from("studio_settings").select("gift_card_image_path")
    .eq("studio_id", ctx.studioId).maybeSingle();
  const ext = file.type === "image/png" ? "png" : "jpg";
  const path = `${ctx.studioId}/gift-card-${Date.now()}.${ext}`;
  const { error } = await supabase.storage.from("studio-branding")
    .upload(path, file, { cacheControl: IMMUTABLE_YEAR, upsert: false });
  if (error) return { ok: false, message: /row-level security|Unauthorized/i.test(error.message)
    ? "Only owners and managers change the gift card image." : error.message };
  const { data: pub } = supabase.storage.from("studio-branding").getPublicUrl(path);
  const { data: rows, error: upErr } = await supabase.from("studio_settings")
    .update({ gift_card_image_path: pub.publicUrl }).eq("studio_id", ctx.studioId).select("studio_id");
  if (upErr) return { ok: false, message: upErr.message };
  if (!rows?.length) return { ok: false, message: "The image uploaded but the setting could not be saved." };
  const old = objectPathFromPublicUrl(prev?.gift_card_image_path ?? null, "studio-branding");
  if (old && old !== path) await supabase.storage.from("studio-branding").remove([old]);
  revalidatePath("/settings/memberships");
  return { ok: true, message: "Gift card image updated. New cards use it." };
}

export async function removeGiftCardImage(_p: PrivState): Promise<PrivState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const supabase = createClient();
  const { data: prev } = await supabase.from("studio_settings").select("gift_card_image_path")
    .eq("studio_id", ctx.studioId).maybeSingle();
  await supabase.from("studio_settings").update({ gift_card_image_path: null }).eq("studio_id", ctx.studioId);
  const old = objectPathFromPublicUrl(prev?.gift_card_image_path ?? null, "studio-branding");
  if (old) await supabase.storage.from("studio-branding").remove([old]);
  revalidatePath("/settings/memberships");
  return { ok: true, message: "Removed. New cards use the default card in your studio colour." };
}
