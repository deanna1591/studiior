import { anonStudio } from "@/lib/anon-studio";
import { accentRamp, neutralAccent, PRESETS, type PresetKey } from "@/lib/theme";
import { manifestObject, iconVersion } from "@/lib/pwa";

/**
 * Decision 51 — a per-tenant Web App Manifest, derived entirely from Branding.
 * `which` is the member app ("/") or the instructor portal ("/instructor"),
 * which installs as a separate app ("{Studio} — Instructors") in its own scope.
 * Returns null when the host has no known studio (the route 404s).
 */
export async function buildManifest(which: "member" | "instructor"): Promise<Response | null> {
  const studio = await anonStudio();
  if (!studio?.name) return null;

  const preset = (studio.theme_preset ?? "warm") as PresetKey;
  const accent = studio.accent_color ?? neutralAccent(preset);
  const ramp = accentRamp(accent, preset);

  const manifest = manifestObject({
    slug: studio.slug,
    name: studio.name,
    themeColor: ramp.fill,
    backgroundColor: PRESETS[preset].paper,
    iconV: iconVersion(studio.logo_url),
  }, which);

  return new Response(JSON.stringify(manifest), {
    headers: {
      "Content-Type": "application/manifest+json; charset=utf-8",
      // Short cache: the manifest itself is cheap and must reflect a Branding
      // change quickly; the heavy icons it points at are the immutable ones.
      "Cache-Control": "public, max-age=300",
    },
  });
}
