import { ImageResponse } from "next/og";
import { anonStudio } from "@/lib/anon-studio";
import { accentRamp, neutralAccent, type PresetKey } from "@/lib/theme";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * Decision 51 — a home-screen icon, generated from Branding, never hand-made.
 * The studio's logo on a square of its accent (or the neutral initial letter
 * when there is no logo), at 180 / 192 / 512, plus a maskable 512 with safe
 * padding. Rendered with next/og's ImageResponse — sharp is not a dependency.
 *
 * Reached at /icon/180 · /icon/192 · /icon/512 · /icon/maskable (extension-less,
 * because the middleware matcher excludes .png; the manifest and the
 * apple-touch-icon <link> reference these paths and carry the PNG Content-Type
 * and manifest `type`). Cached immutably — the manifest/links append ?v=<logo
 * version>, so a new logo is a new URL.
 */
export async function GET(_req: Request, { params }: { params: { size: string } }) {
  const studio = await anonStudio();
  if (!studio) return new Response("Not found", { status: 404 });

  const maskable = params.size === "maskable";
  const size = maskable ? 512 : Number(params.size);
  if (!maskable && ![180, 192, 512].includes(size)) {
    return new Response("Unsupported size", { status: 400 });
  }

  const preset = (studio.theme_preset ?? "warm") as PresetKey;
  const accent = studio.accent_color ?? neutralAccent(preset);
  const ramp = accentRamp(accent, preset);
  const logo = studio.logo_url ?? null;

  // Maskable icons are cropped to a circle/squircle by the OS, so the content
  // must stay inside the inner ~80% safe zone; a plain icon can fill more.
  const pad = maskable ? Math.round(size * 0.2) : Math.round(size * 0.14);
  const inner = size - pad * 2;

  return new ImageResponse(
    (
      <div
        style={{
          width: size, height: size, display: "flex",
          alignItems: "center", justifyContent: "center",
          background: ramp.fill,
        }}
      >
        {logo ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={logo} width={inner} height={inner}
               style={{ width: inner, height: inner, objectFit: "contain" }} />
        ) : (
          <div style={{
            display: "flex", alignItems: "center", justifyContent: "center",
            width: inner, height: inner,
            fontSize: Math.round(inner * 0.62), fontWeight: 700,
            color: ramp.onSolid,
          }}>
            {(studio.name ?? "?").slice(0, 1).toUpperCase()}
          </div>
        )}
      </div>
    ),
    {
      width: size, height: size,
      headers: {
        // Immutable: the referencing URL carries ?v=<logo version>, so a logo
        // change is a different URL rather than a stale cache.
        "Cache-Control": "public, max-age=31536000, immutable",
      },
    },
  );
}
