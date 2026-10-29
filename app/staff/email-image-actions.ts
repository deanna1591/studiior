"use server";

import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";
import { renderBody } from "@/lib/email-body";

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
    .upload(path, file, { cacheControl: "31536000, immutable", upsert: false });
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

export type ResolvedCard = { name: string; detail?: string; price?: string; button?: { label: string; url: string } };

/**
 * Decision 80a — resolve a `::: plan <id>` / `::: class <id>` shorthand to its card
 * fields for the composer preview, so a studio can drop a live plan card. Reads the
 * caller's own studio; uses the SAME plan_card_detail / fmt_money the emails use.
 */
export async function resolveEmailCard(kind: string, id: string): Promise<ResolvedCard | null> {
  const ctx = await getStaffContext();
  if (!ctx) return null;
  const supabase = createClient();
  if (kind === "plan") {
    const { data: p } = await supabase.from("membership_plans")
      .select("id, name, price_cents, currency").eq("id", id).eq("studio_id", ctx.studioId).maybeSingle();
    if (!p) return null;
    const [{ data: detail }, { data: price }] = await Promise.all([
      supabase.rpc("plan_card_detail", { p_plan_id: p.id }),
      supabase.rpc("fmt_money", { p_cents: p.price_cents, p_currency: p.currency }),
    ]);
    const money = (price as string) ?? "";
    return {
      name: p.name as string,
      detail: (detail as string) || undefined,
      price: money || undefined,
      button: { label: money ? `Buy ${p.name} — ${money}` : `See ${p.name}`, url: "{buy_url}" },
    };
  }
  if (kind === "class") {
    const { data: o } = await supabase.from("class_occurrences")
      .select("name, starts_at, rooms(name), instructors(display_name)")
      .eq("id", id).eq("studio_id", ctx.studioId).maybeSingle();
    if (!o) return null;
    const room = (o.rooms as { name?: string } | null)?.name;
    const instr = (o.instructors as { display_name?: string } | null)?.display_name?.split(" ")[0];
    const day = new Date(o.starts_at as string).toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" });
    const detail = [day, room, instr ? `with ${instr}` : null].filter(Boolean).join(" · ");
    return { name: o.name as string, detail };
  }
  return null;
}

export type PreviewResult = { subject?: string; html?: string; stripped?: string[]; error?: string };

/**
 * Decision 80d — render a composed email through the REAL frame for the live
 * preview. The markup body is turned into HTML here (the ONE renderer, with the
 * {accent} token so render_email fills the studio's own colour, exactly as the
 * send path does), then preview_template wraps it in the studio's frame with a
 * sample context and NO notification row written (the RPC is STABLE). Returns the
 * full-document HTML the composer drops into an iframe. Manager-up in the RPC.
 */
export async function previewEmail(templateKey: string, subject: string, body: string): Promise<PreviewResult> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };

  // Pre-resolve any ::: plan/class card shorthands so renderBody's sync resolver
  // can fill them (the composer used to do this client-side; it is server-side now).
  const cards: Record<string, ResolvedCard | null> = {};
  for (const m of body.matchAll(/^:::\s+(plan|class)\s+(\S+)\s*$/gm)) {
    const key = `${m[1]}:${m[2]}`;
    if (key in cards) continue;
    cards[key] = await resolveEmailCard(m[1], m[2]);
  }
  const html = renderBody(body, {
    accent: "{accent}",
    resolve: (kind, idv) => cards[`${kind}:${idv}`] ?? null,
  }).html;

  const supabase = createClient();
  const { data, error } = await supabase.rpc("preview_template", {
    p_studio_id: ctx.studioId, p_key: templateKey, p_subject: subject, p_body: html,
  });
  if (error) {
    return /PT403|manager|owner/i.test(error.message)
      ? { error: "Your role cannot preview templates." }
      : { error: error.message };
  }
  const r = (data ?? {}) as { subject?: string; html?: string; stripped?: string[] };
  return { subject: r.subject, html: r.html, stripped: r.stripped ?? [] };
}
