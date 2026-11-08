import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext, isDeskUp } from "@/lib/auth";
import { parseBrandSpec, isValidSpec, BRAND_FONTS, type BrandSpec } from "@/lib/brand-kit";
import { parseApiResponse } from "@/lib/ai-draft";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * Decision 93 slice 3 — "Tell Claude what to change". Desk-up, SERVER-SIDE ONLY.
 * Takes the current post spec, a plain-language instruction and an optional photo
 * (uploaded to the private post-images bucket). Calls the Claude API through the
 * existing x-api-key path and asks for an updated spec in the SAME shape — Claude
 * fills the spec, never an image. The reply is validated with parseBrandSpec;
 * anything off-shape is refused with the recorded sentence. The run gate caps at
 * sixty edits a month (post_edit_run_allowed). No image is ever returned.
 */

const MODEL = "claude-sonnet-5-5";
const PHOTO_MIME: Record<string, string> = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", webp: "image/webp" };
const MAX_PHOTO = 5_242_880;

function sys(studioName: string): string {
  return [
    `You adjust the visual spec for a social post of a class timetable for the studio "${studioName}". Our renderer draws the post from the spec; you only edit the spec.`,
    `Apply the user's instruction and return the FULL updated spec as a single JSON object — no prose, no markdown fence, no image. Change ONLY what the instruction asks; keep every other field exactly as given.`,
    `The object is:`,
    `{`,
    `  "colors": { "background": "#rrggbb", "surface": "#rrggbb", "ink": "#rrggbb", "accent": "#rrggbb", "secondary": "#rrggbb" },`,
    `  "display_font": <font>, "body_font": <font>,`,
    `  "layout": "list"|"grid"|"poster", "radius": "small"|"large",`,
    `  "tone": <one line, <=200 chars>,`,
    `  "logo_placement": "top-left"|"top-centre"|"bottom",`,
    `  "background_treatment": "none"|"soft"|"full",`,
    `  // optional, include only when relevant:`,
    `  "background_image": <a post-images path, set only when a photo is attached>,`,
    `  "image_placement": "top"|"left"|"right"|"full",`,
    `  "overlay_strength": <0..1, how dark the colour over the photo>,`,
    `  "text_align": "left"|"center"|"right",`,
    `  "size_scale": { "time": <0.5..2>, "name": <0.5..2>, "header": <0.5..2> },`,
    `  "element_order": array of "logo","title","classes","footer"`,
    `}`,
    `Every colour is a 6-digit hex. The two fonts MUST be from this list exactly: ${BRAND_FONTS.join(", ")}.`,
    `When a photo is attached, set "background_treatment" to "full" (or "soft" if the user wants the colour to show through), set "background_image" to the path you are told, and pick an "overlay_strength" that keeps the text readable.`,
  ].join("\n");
}

export async function POST(req: Request): Promise<NextResponse> {
  const ctx = await getStaffContext();
  if (!ctx) return NextResponse.json({ error: "You are not signed in." }, { status: 401 });
  if (!isDeskUp(ctx.role)) return NextResponse.json({ error: "Only the studio team can edit posts." }, { status: 403 });

  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) return NextResponse.json({ error: "AI isn't set up on this platform yet." }, { status: 503 });

  const form = await req.formData();
  const instruction = String(form.get("instruction") ?? "").trim().slice(0, 500);
  if (!instruction) return NextResponse.json({ error: "Say what you'd like to change." }, { status: 400 });

  let current: BrandSpec;
  try {
    const parsed = JSON.parse(String(form.get("spec") ?? ""));
    if (!isValidSpec(parsed)) throw new Error("bad spec");
    current = parsed as BrandSpec;
  } catch {
    return NextResponse.json({ error: "Couldn't read the current post." }, { status: 400 });
  }

  const supabase = createClient();

  // Gate: increment + refuse past sixty a month (desk-up).
  const { data: gate, error: gateErr } = await supabase.rpc("post_edit_run_allowed", { p_studio_id: ctx.studioId });
  if (gateErr) return NextResponse.json({ error: "Could not start. Try again." }, { status: 400 });
  const g = (gate ?? {}) as { ok?: boolean; reason?: string; used?: number; cap?: number };
  if (!g.ok) {
    return NextResponse.json(
      { error: `You've used all ${g.cap ?? 60} post edits this month.`, reason: g.reason ?? "post_edit_limit", used: g.used, cap: g.cap },
      { status: 429 });
  }

  // Optional photo -> post-images (desk-up policy), then a vision block + a path
  // the model must reference as background_image.
  let photoPath: string | null = null;
  const visionBlocks: Array<Record<string, unknown>> = [];
  const photo = form.get("photo") as File | null;
  if (photo && photo.size > 0) {
    const ext = photo.name.split(".").pop()?.toLowerCase() ?? "";
    const media = PHOTO_MIME[ext];
    if (!media) return NextResponse.json({ error: "Photos must be PNG, JPG or WEBP." }, { status: 400 });
    if (photo.size > MAX_PHOTO) return NextResponse.json({ error: "That photo is over 5 MB." }, { status: 400 });
    const yyyymm = new Date().toISOString().slice(0, 7);
    photoPath = `${ctx.studioId}/${yyyymm}/edit-${Date.now()}.${ext}`;
    const { error: upErr } = await supabase.storage.from("post-images").upload(photoPath, photo, { upsert: false, contentType: media });
    if (upErr) {
      return /row-level security|Unauthorized/i.test(upErr.message)
        ? NextResponse.json({ error: "Your role cannot upload photos." }, { status: 403 })
        : NextResponse.json({ error: "Could not save the photo. Try again." }, { status: 400 });
    }
    const b64 = Buffer.from(await photo.arrayBuffer()).toString("base64");
    visionBlocks.push({ type: "image", source: { type: "base64", media_type: media, data: b64 } });
  }

  const content: Array<Record<string, unknown>> = [...visionBlocks, {
    type: "text",
    text: [
      `Current spec:`,
      JSON.stringify(current),
      photoPath
        ? `A photo is attached. Use it as the background and set "background_image" to exactly: ${photoPath}`
        : `No photo is attached.`,
      `Instruction: ${instruction}`,
      `Return the full updated spec JSON now.`,
    ].join("\n"),
  }];

  let json: unknown;
  try {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: MODEL, max_tokens: 800, system: sys(ctx.studioName), messages: [{ role: "user", content }] }),
      signal: AbortSignal.timeout(45_000),
    });
    if (!res.ok) return NextResponse.json({ error: "Couldn't apply that. Try saying it another way." }, { status: 422 });
    json = await res.json();
  } catch {
    return NextResponse.json({ error: "Couldn't apply that. Try saying it another way." }, { status: 422 });
  }

  const { text } = parseApiResponse(json);
  const spec = parseBrandSpec(text);
  if (!spec) return NextResponse.json({ error: "Couldn't apply that. Try saying it another way." }, { status: 422 });

  // The uploaded photo wins — the model cannot drop or rename it.
  if (photoPath) {
    spec.background_image = photoPath;
    if (spec.background_treatment === "none") spec.background_treatment = "full";
  }

  return NextResponse.json({ ok: true, spec, used: g.used, cap: g.cap });
}
