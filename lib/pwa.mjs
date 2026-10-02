// Decision 51 — shared copy and helpers for the per-tenant PWA, so the login
// page, the Branding preview, the Install page and the manifest all agree on
// the defaults a studio has not overridden. Plain ESM so `node --test` runs the
// pure helpers (incl. manifestObject) with no bundler; a sibling .d.ts types it
// for the app under moduleResolution: bundler.

/** The sign-in sub-line shown when a studio sets no login_tagline. */
export const DEFAULT_LOGIN_TAGLINE = "Book your classes, check in, and see your plan.";

/** The sign-in sub-line for a studio (its own, or the default). */
export function loginTagline(custom) {
  const v = (custom ?? "").trim();
  return v === "" ? DEFAULT_LOGIN_TAGLINE : v;
}

/** The Install-page welcome line for a studio (its own, or the default, which
 *  names the studio). */
export function installWelcome(studioName, custom) {
  const v = (custom ?? "").trim();
  return v === "" ? `Add ${studioName} to your home screen for one-tap booking.` : v;
}

/** short_name for a manifest — the studio name, capped at 12 chars (the Web App
 *  Manifest convention for the home-screen label) on a word boundary where it
 *  can, otherwise a hard cut. */
export function shortName(studioName) {
  const n = (studioName ?? "").trim();
  if (n.length <= 12) return n;
  const cut = n.slice(0, 12);
  const sp = cut.lastIndexOf(" ");
  return (sp >= 6 ? cut.slice(0, sp) : cut).trim();
}

/** A short, stable version tag derived from the logo URL (or "none"), so icon
 *  URLs change when the logo does and can otherwise be cached immutably. djb2,
 *  base36 — not for security, only cache-busting. */
export function iconVersion(logoUrl) {
  const s = logoUrl ?? "none";
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
  return h.toString(36);
}

/**
 * The Web App Manifest object for a tenant, PURE — the colours are resolved by
 * the caller (from accent/preset) and passed in, so this has no theme or I/O
 * dependency and is node-testable. `which` is "member" ("/") or "instructor"
 * ("/instructor", installed separately as "{name} — Instructors").
 */
export function manifestObject({ slug, name, themeColor, backgroundColor, iconV }, which) {
  const isInstructor = which === "instructor";
  const appName = isInstructor ? `${name} — Instructors` : name;
  const start = isInstructor ? "/instructor" : "/";
  const icon = (spec) => `/icon/${spec}?v=${iconV}`;
  return {
    id: isInstructor ? `${slug}-instructor` : slug,
    name: appName,
    short_name: shortName(name),
    start_url: start,
    scope: start,
    display: "standalone",
    background_color: backgroundColor,
    theme_color: themeColor,
    icons: [
      { src: icon("192"), sizes: "192x192", type: "image/png", purpose: "any" },
      { src: icon("512"), sizes: "512x512", type: "image/png", purpose: "any" },
      { src: icon("maskable"), sizes: "512x512", type: "image/png", purpose: "maskable" },
    ],
  };
}
