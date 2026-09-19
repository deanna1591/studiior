"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

export type AnnFormState = { error: string } | null;
export type CoverState = { ok: boolean; message: string } | null;

// dates from the form are wall-calendar dates; store the window as UTC instants
// so "in range" is a clean day boundary.
const startISO = (d: string) => (d ? `${d}T00:00:00Z` : null);
const endISO = (d: string) => (d ? `${d}T23:59:59Z` : null);

async function storeCover(id: string, studioId: string, file: File): Promise<CoverState> {
  if (file.size > 2_000_000) return { ok: false, message: "That photo is over 2 MB. Export it around 1600px wide." };
  if (!["image/png", "image/jpeg", "image/webp"].includes(file.type)) return { ok: false, message: "JPEG, PNG or WebP." };
  const supabase = createClient();
  const ext = file.name.split(".").pop()?.toLowerCase() ?? "jpg";
  const path = `${studioId}/announcement-${id}-${Date.now()}.${ext}`;
  const { error } = await supabase.storage.from("studio-branding").upload(path, file, { cacheControl: "3600", upsert: false });
  if (error) return /row-level security|Unauthorized/i.test(error.message)
    ? { ok: false, message: "Only owners and managers can change the photo." } : { ok: false, message: error.message };
  const { data: pub } = supabase.storage.from("studio-branding").getPublicUrl(path);
  const { data: rows, error: upErr } = await supabase.from("announcements")
    .update({ image_url: pub.publicUrl, image_focus_x: 50, image_focus_y: 50 }).eq("id", id).select("id");
  if (upErr) return { ok: false, message: upErr.message };
  if (!rows?.length) return { ok: false, message: "The photo uploaded but the announcement could not be updated." };
  return { ok: true, message: "Photo updated. Set the focal point below so it crops well on a phone." };
}

export async function uploadAnnouncementCover(_prev: CoverState, fd: FormData): Promise<CoverState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "Not signed in." };
  const id = String(fd.get("announcement_id") ?? "");
  const file = fd.get("cover") as File | null;
  if (!file || file.size === 0) return { ok: false, message: "Choose a photo first." };
  const res = await storeCover(id, ctx.studioId, file);
  if (res?.ok) { revalidatePath(`/announcements/${id}`); revalidatePath("/announcements"); }
  return res;
}

export async function saveAnnouncementCoverFocus(_prev: CoverState, fd: FormData): Promise<CoverState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "Not signed in." };
  const id = String(fd.get("announcement_id") ?? "");
  const clamp = (k: string) => Math.min(100, Math.max(0, Math.round(Number(fd.get(k) ?? 50))));
  const supabase = createClient();
  const { data, error } = await supabase.from("announcements")
    .update({ image_focus_x: clamp("focus_x"), image_focus_y: clamp("focus_y") }).eq("id", id).select("id");
  if (error) return { ok: false, message: error.message };
  if (!data?.length) return { ok: false, message: "Nothing was saved. Owners and managers only." };
  revalidatePath(`/announcements/${id}`);
  return { ok: true, message: "Saved." };
}

function fields(fd: FormData) {
  const kind = String(fd.get("kind") ?? "post") === "banner" ? "banner" : "post";
  const title = String(fd.get("title") ?? "").trim();
  const body = String(fd.get("body") ?? "").trim();
  const audience = String(fd.get("audience") ?? "members");
  const pinned = fd.get("pinned") === "on";
  const starts = startISO(String(fd.get("starts_on") ?? ""));
  const ends = endISO(String(fd.get("ends_on") ?? ""));
  const linkUrl = String(fd.get("link_url") ?? "").trim() || null;
  const linkLabel = String(fd.get("link_label") ?? "").trim() || null;
  return { kind, title, body, audience, pinned, starts, ends, linkUrl, linkLabel };
}

export async function createAnnouncement(_prev: AnnFormState, fd: FormData): Promise<AnnFormState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };
  const supabase = createClient();
  const f = fields(fd);
  if (!f.title) return { error: "An announcement needs a title." };
  if (f.kind === "post" && !f.body) return { error: "A What’s-on post needs a body." };
  const { data, error } = await supabase.rpc("create_announcement", {
    p_studio_id: ctx.studioId, p_title: f.title, p_body: f.body,
    p_starts_at: f.starts ?? new Date().toISOString(), p_ends_at: f.ends as unknown as string,
    p_audience: f.audience, p_pinned: f.pinned,
    p_kind: f.kind, p_link_url: f.linkUrl as unknown as string, p_link_label: f.linkLabel as unknown as string,
  });
  if (error) return { error: error.message };
  // A banner has no photo; only a post's cover is stored.
  const cover = fd.get("cover") as File | null;
  if (f.kind === "post" && cover && cover.size > 0) await storeCover(data as string, ctx.studioId, cover);
  revalidatePath("/announcements");
  redirect(`/announcements/${data as string}`);
}

export async function updateAnnouncement(_prev: AnnFormState, fd: FormData): Promise<AnnFormState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };
  const supabase = createClient();
  const id = String(fd.get("announcement_id") ?? "");
  const f = fields(fd);
  if (!f.title) return { error: "An announcement needs a title." };
  if (f.kind === "post" && !f.body) return { error: "A What’s-on post needs a body." };
  const { error } = await supabase.rpc("update_announcement", {
    p_id: id, p_title: f.title, p_body: f.body, p_starts_at: f.starts as unknown as string, p_ends_at: f.ends as unknown as string,
    p_audience: f.audience, p_pinned: f.pinned,
    p_kind: f.kind, p_link_url: f.linkUrl as unknown as string, p_link_label: f.linkLabel as unknown as string,
  });
  if (error) return { error: error.message };
  revalidatePath("/announcements");
  revalidatePath(`/announcements/${id}`);
  return null;
}

export async function publishAnnouncement(fd: FormData): Promise<void> {
  const ctx = await getStaffContext();
  if (!ctx) return;
  const supabase = createClient();
  const id = String(fd.get("announcement_id") ?? "");
  const notify = fd.get("notify") === "on";
  const { error } = await supabase.rpc("publish_announcement", { p_id: id, p_notify: notify });
  if (error) throw new Error(error.message);
  revalidatePath("/announcements"); revalidatePath(`/announcements/${id}`); revalidatePath("/");
}

export async function unpublishAnnouncement(fd: FormData): Promise<void> {
  const ctx = await getStaffContext();
  if (!ctx) return;
  const supabase = createClient();
  const id = String(fd.get("announcement_id") ?? "");
  const { error } = await supabase.rpc("unpublish_announcement", { p_id: id });
  if (error) throw new Error(error.message);
  revalidatePath("/announcements"); revalidatePath(`/announcements/${id}`);
}

export async function deleteAnnouncement(fd: FormData): Promise<void> {
  const ctx = await getStaffContext();
  if (!ctx) return;
  const supabase = createClient();
  const id = String(fd.get("announcement_id") ?? "");
  const { error } = await supabase.rpc("delete_announcement", { p_id: id });
  if (error) throw new Error(error.message);
  revalidatePath("/announcements");
  redirect("/announcements");
}
