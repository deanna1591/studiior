import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";
import { parseBrandSpec, BRAND_FONTS } from "@/lib/brand-kit";
import { parseApiResponse } from "@/lib/ai-draft";
import type { Json } from "@/lib/database.types";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * Decision 93 slice 1 — "Learn my style". Manager-up, SERVER-SIDE ONLY. Loads
 * the studio's brand references (private bucket, read as the signed-in manager
 * under RLS) plus the logo and name, calls the Claude API through the existing
 * x-api-key path (the key is process.env.ANTHROPIC_API_KEY, never the browser),
 * asks for the brand spec as strict JSON, validates it (parseBrandSpec rejects
 * anything off-shape), and saves it via brand_kit_save with source 'learned'.
 * The run gate (brand_kit_run_allowed) caps at ten a month BEFORE the call.
 * Claude only fills the spec; our renderer draws the posts.
 */

const MODEL = "claude-sonnet-5-5";
const MIME: Record<string, string> = {
  png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", pdf: "application/pdf",
};

function sys(studioName: string): string {
  return [
    `You are a brand designer. Look at the reference designs and the logo for the studio "${studioName}" and describe its visual brand as a single JSON object, so our renderer can draw social posts in the same look.`,
    `Respond with ONLY the JSON object — no prose, no markdown fence. The object must be exactly:`,
    `{`,
    `  "colors": { "background": "#rrggbb", "surface": "#rrggbb", "ink": "#rrggbb", "accent": "#rrggbb", "secondary": "#rrggbb" },`,
    `  "display_font": <one of the fonts>, "body_font": <one of the fonts>,`,
    `  "layout": "list" | "grid" | "poster",`,
    `  "radius": "small" | "large",`,
    `  "tone": <a one-line description, at most 200 characters>,`,
    `  "logo_placement": "top-left" | "top-centre" | "bottom",`,
    `  "background_treatment": "none" | "soft" | "full"`,
    `}`,
    `Every colour is a 6-digit hex. "background" is the page, "surface" is a card, "ink" is the main text, "accent" is the brand highlight, "secondary" is a muted supporting colour.`,
    `The two fonts MUST be chosen from this list exactly: ${BRAND_FONTS.join(", ")}.`,
    `"layout": list = a vertical list of classes, grid = a day grid, poster = one bold hero. "background_treatment": none = solid colour, soft = a photo behind a colour overlay, full = a full-bleed photo.`,
    `Pick the closest match for each field even if the references are not an exact fit.`,
  ].join("\n");
}

export async function POST(): Promise<NextResponse> {
  const ctx = await getStaffContext();
  if (!ctx) return NextResponse.json({ error: "You are not signed in." }, { status: 401 });
  if (ctx.role !== "owner" && ctx.role !== "manager") {
    return NextResponse.json({ error: "Only owners and managers can learn the brand kit." }, { status: 403 });
  }

  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) return NextResponse.json({ error: "AI isn't set up on this platform yet." }, { status: 503 });

  const supabase = createClient();

  // Gate: increment + refuse past ten a month (manager-up).
  const { data: gate, error: gateErr } = await supabase.rpc("brand_kit_run_allowed", { p_studio_id: ctx.studioId });
  if (gateErr) return NextResponse.json({ error: "Could not start. Try again." }, { status: 400 });
  const g = (gate ?? {}) as { ok?: boolean; reason?: string; used?: number; cap?: number };
  if (!g.ok) {
    return NextResponse.json(
      { error: `You've used all ${g.cap ?? 10} "Learn my style" runs this month.`, reason: g.reason ?? "brand_kit_limit" },
      { status: 429 });
  }

  // Load up to five references from the private bucket (read as the manager).
  const content: Array<Record<string, unknown>> = [];
  const { data: list } = await supabase.storage.from("brand-references").list(ctx.studioId, {
    limit: 20, sortBy: { column: "name", order: "asc" },
  });
  const files = (list ?? []).filter((f) => f.name && f.id).slice(0, 5);
  for (const f of files) {
    const ext = f.name.split(".").pop()?.toLowerCase() ?? "";
    const media = MIME[ext];
    if (!media) continue;
    const { data: blob } = await supabase.storage.from("brand-references").download(`${ctx.studioId}/${f.name}`);
    if (!blob) continue;
    const b64 = Buffer.from(await blob.arrayBuffer()).toString("base64");
    content.push(media === "application/pdf"
      ? { type: "document", source: { type: "base64", media_type: media, data: b64 } }
      : { type: "image", source: { type: "base64", media_type: media, data: b64 } });
  }
  if (content.length === 0) {
    return NextResponse.json({ error: "Upload at least one reference design first." }, { status: 400 });
  }

  // The logo, if the studio has one (a public URL — fetched and inlined).
  const { data: studio } = await supabase.from("studios").select("logo_url").eq("id", ctx.studioId).maybeSingle();
  if (studio?.logo_url) {
    try {
      const r = await fetch(studio.logo_url, { signal: AbortSignal.timeout(10_000) });
      if (r.ok) {
        const ct = r.headers.get("content-type") ?? "";
        const media = ct.includes("png") ? "image/png" : ct.includes("webp") ? "image/webp"
          : ct.includes("svg") ? "" : "image/jpeg";
        if (media) {
          const b64 = Buffer.from(await r.arrayBuffer()).toString("base64");
          content.push({ type: "image", source: { type: "base64", media_type: media, data: b64 } });
        }
      }
    } catch { /* logo is optional */ }
  }
  content.push({ type: "text", text: `This studio is called "${ctx.studioName}". Give the brand spec JSON now.` });

  // Call Claude (vision) through the existing x-api-key path.
  let json: unknown;
  try {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: MODEL, max_tokens: 800, system: sys(ctx.studioName), messages: [{ role: "user", content }] }),
      signal: AbortSignal.timeout(45_000),
    });
    if (!res.ok) return NextResponse.json({ error: "Could not read the references. Try clearer exports." }, { status: 422 });
    json = await res.json();
  } catch {
    return NextResponse.json({ error: "Could not read the references. Try clearer exports." }, { status: 422 });
  }

  const { text } = parseApiResponse(json);
  const spec = parseBrandSpec(text);
  if (!spec) return NextResponse.json({ error: "Could not read the references. Try clearer exports." }, { status: 422 });

  const { error: saveErr } = await supabase.rpc("brand_kit_save", {
    p_studio_id: ctx.studioId, p_spec: spec as unknown as Json, p_source: "learned",
  });
  if (saveErr) return NextResponse.json({ error: "Learned, but couldn't save. Try again." }, { status: 500 });

  return NextResponse.json({ ok: true, spec, source: "learned" });
}
