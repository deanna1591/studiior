import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext, isDeskUp } from "@/lib/auth";
import { parseBrandSpec, isValidSpec, BRAND_FONTS, type BrandSpec } from "@/lib/brand-kit";
import { parseApiResponse } from "@/lib/ai-draft";
import { editResult } from "@/lib/post-edit";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * Decision 93 slice 3 + amendment — "Tell Claude what to change". Desk-up,
 * SERVER-SIDE ONLY. Takes the current post spec, a plain-language instruction and
 * an optional photo PATH (the browser uploads the photo straight to post-images
 * with the signed-in session, so the request body never carries a file and the
 * Vercel 4.5 MB ceiling is not in play). The route reads the object from the
 * bucket server-side for the vision block. Calls the Claude API through the
 * existing x-api-key path and asks for an updated spec in the SAME shape — Claude
 * fills the spec, never an image. The reply is validated with parseBrandSpec;
 * a photo always applies even when the worded change can't be read. Each failure
 * returns a specific reason and logs the status + first 300 chars of the API body
 * (never the key). The run gate caps at sixty edits a month.
 */

const MODEL = "claude-sonnet-5-5";
const MAX_PHOTO = 5_242_880;
const PATH_MIME: Record<string, string> = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", webp: "image/webp" };
const TAG = "[schedule-post/edit]";

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
    `  "element_order": array of "logo","title","classes","footer",`,
    `  "watermark_opacity": <0..0.4, a faint centred kit logo behind everything; set a small value like 0.12 when asked for a subtle, faint or background logo; 0 or omit for none>`,
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

  // Optional photo: the BROWSER uploaded it to post-images (desk-up policy) and
  // POSTs only the path — the request body never carries a file. Read the object
  // server-side for the vision block; the path becomes background_image.
  let photoPath: string | null = null;
  const visionBlocks: Array<Record<string, unknown>> = [];
  const rawPath = String(form.get("photo_path") ?? "").trim();
  if (rawPath) {
    if (!rawPath.startsWith(`${ctx.studioId}/`)) return NextResponse.json({ error: "That photo isn't yours." }, { status: 403 });
    const ext = rawPath.split(".").pop()?.toLowerCase() ?? "";
    const media = PATH_MIME[ext];
    if (!media) return NextResponse.json({ error: "Photos must be PNG, JPG or WEBP." }, { status: 400 });
    const { data: blob, error: dlErr } = await supabase.storage.from("post-images").download(rawPath);
    if (dlErr || !blob) {
      console.error(TAG, "photo download failed", dlErr?.message);
      return NextResponse.json({ error: "Could not read that photo. Try again." }, { status: 400 });
    }
    if (blob.size > MAX_PHOTO) return NextResponse.json({ error: "That photo is over 5 MB." }, { status: 400 });
    photoPath = rawPath;
    const b64 = Buffer.from(await blob.arrayBuffer()).toString("base64");
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

  let res: Response;
  let body = "";
  try {
    res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: MODEL, max_tokens: 800, system: sys(ctx.studioName), messages: [{ role: "user", content }] }),
      signal: AbortSignal.timeout(45_000),
    });
    body = await res.text();
  } catch (e) {
    const err = e as { name?: string };
    const timeout = err?.name === "TimeoutError" || err?.name === "AbortError";
    console.error(TAG, "fetch failed", err?.name ?? "unknown");
    return timeout
      ? NextResponse.json({ error: "That took too long. Try again." }, { status: 504 })
      : NextResponse.json({ error: "Couldn't apply that. Try saying it another way." }, { status: 422 });
  }

  if (!res.ok) {
    console.error(TAG, "api non-ok", res.status, body.slice(0, 300));
    if (res.status === 401 || res.status === 403) {
      return NextResponse.json({ error: "AI isn't set up on this platform yet." }, { status: 503 });
    }
    if (res.status === 400 && /image|dimension|pixels|too large|too many/i.test(body)) {
      return NextResponse.json({ error: "That photo is too large for the editor." }, { status: 400 });
    }
    return NextResponse.json({ error: "Couldn't apply that. Try saying it another way." }, { status: 422 });
  }

  let json: unknown;
  try { json = JSON.parse(body); }
  catch {
    console.error(TAG, "unreadable JSON", res.status, body.slice(0, 300));
    json = null;
  }
  const { text } = parseApiResponse(json);
  const result = editResult(parseBrandSpec(text), { photoPath, current });
  if (!result.ok) {
    console.error(TAG, "unreadable reply", res.status, String(text ?? "").slice(0, 300));
    return NextResponse.json({ error: "Couldn't apply that. Try saying it another way." }, { status: 422 });
  }
  return NextResponse.json({ ok: true, spec: result.spec, note: result.note, used: g.used, cap: g.cap });
}
