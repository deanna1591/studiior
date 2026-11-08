// Decision 93 slice 1 — the brand kit spec: its font list, validation and
// defaults. The SQL mirror is brand_kit_valid / brand_kit_defaults
// (20260833240000). Zero deps so `node --test test/brand-kit.test.mjs` runs it.
//
// Spec shape:
//   { colors: { background, surface, ink, accent, secondary } (6-hex each),
//     display_font, body_font   (from BRAND_FONTS),
//     layout: list|grid|poster, radius: small|large, tone: <=200 chars,
//     logo_placement: top-left|top-centre|bottom,
//     background_treatment: none|soft|full }

/** The vendored open-font list (public/fonts/brand + invoice). */
export const BRAND_FONTS = [
  "Instrument Serif", "Bodoni Moda", "Playfair Display", "Manrope", "Space Grotesk",
  "Inter", "Space Mono", "DM Sans", "Fraunces", "Cormorant",
];
export const LAYOUTS = ["list", "grid", "poster"];
export const RADII = ["small", "large"];
export const LOGO_PLACEMENTS = ["top-left", "top-centre", "bottom"];
export const BACKGROUND_TREATMENTS = ["none", "soft", "full"];

// Optional per-post layout fields (slice 3 — "edit the post with Claude"). All
// OPTIONAL, so a slice-1/2 kit with none of them validates unchanged.
export const IMAGE_PLACEMENTS = ["top", "left", "right", "full"];
export const TEXT_ALIGNS = ["left", "center", "right"];
export const ORDER_TOKENS = ["logo", "title", "classes", "footer"];
const SIZE_KEYS = ["time", "name", "header"];

const COLOR_KEYS = ["background", "surface", "ink", "accent", "secondary"];
const HEX6 = /^#[0-9a-fA-F]{6}$/;
const num = (v) => typeof v === "number" && Number.isFinite(v);

/** True iff the spec matches the shape exactly (colours 6-hex, fonts/enums in
 *  list). The optional layout fields, when present, must be in range; absent is
 *  always valid (existing kits pass unchanged). */
export function isValidSpec(spec) {
  if (!spec || typeof spec !== "object") return false;
  const c = spec.colors;
  if (!c || typeof c !== "object") return false;
  if (!COLOR_KEYS.every((k) => typeof c[k] === "string" && HEX6.test(c[k]))) return false;
  if (!BRAND_FONTS.includes(spec.display_font)) return false;
  if (!BRAND_FONTS.includes(spec.body_font)) return false;
  if (!LAYOUTS.includes(spec.layout)) return false;
  if (!RADII.includes(spec.radius)) return false;
  if (!LOGO_PLACEMENTS.includes(spec.logo_placement)) return false;
  if (!BACKGROUND_TREATMENTS.includes(spec.background_treatment)) return false;
  if (spec.tone != null && (typeof spec.tone !== "string" || spec.tone.length > 200)) return false;
  // optional layout fields
  if (spec.background_image != null && typeof spec.background_image !== "string") return false;
  if (spec.image_placement != null && !IMAGE_PLACEMENTS.includes(spec.image_placement)) return false;
  if (spec.overlay_strength != null && !(num(spec.overlay_strength) && spec.overlay_strength >= 0 && spec.overlay_strength <= 1)) return false;
  if (spec.text_align != null && !TEXT_ALIGNS.includes(spec.text_align)) return false;
  if (spec.size_scale != null) {
    if (typeof spec.size_scale !== "object" || Array.isArray(spec.size_scale)) return false;
    for (const k of SIZE_KEYS) {
      const v = spec.size_scale[k];
      if (v != null && !(num(v) && v >= 0.5 && v <= 2)) return false;
    }
  }
  if (spec.element_order != null) {
    if (!Array.isArray(spec.element_order)) return false;
    if (!spec.element_order.every((t) => ORDER_TOKENS.includes(t))) return false;
  }
  return true;
}

/**
 * Parse Claude's reply into a clean, valid spec, or null. Tolerates a ```json
 * fence and leading prose; keeps ONLY the known keys (so extra keys the model
 * invents can never reach the renderer). Returns null unless the result is a
 * valid spec — the route rejects null with "Could not read the references."
 */
export function parseBrandSpec(text) {
  if (text == null) return null;
  let raw = String(text).trim();
  const fence = raw.match(/^```(?:json)?\s*([\s\S]*?)\s*```$/);
  if (fence) raw = fence[1].trim();
  const brace = raw.indexOf("{");
  if (brace > 0) raw = raw.slice(brace);
  const end = raw.lastIndexOf("}");
  if (end >= 0) raw = raw.slice(0, end + 1);
  let obj;
  try { obj = JSON.parse(raw); } catch { return null; }
  if (!obj || typeof obj !== "object" || !obj.colors || typeof obj.colors !== "object") return null;
  const clean = {
    colors: {},
    display_font: obj.display_font,
    body_font: obj.body_font,
    layout: obj.layout,
    radius: obj.radius,
    tone: typeof obj.tone === "string" ? obj.tone.slice(0, 200) : "",
    logo_placement: obj.logo_placement,
    background_treatment: obj.background_treatment,
  };
  for (const k of COLOR_KEYS) clean.colors[k] = obj.colors[k];
  // Keep the optional layout keys ONLY when present, so a spec without them stays
  // byte-identical. Unknown keys the model invents are dropped (not copied).
  if (typeof obj.background_image === "string") clean.background_image = obj.background_image;
  if (obj.image_placement != null) clean.image_placement = obj.image_placement;
  if (obj.overlay_strength != null) clean.overlay_strength = obj.overlay_strength;
  if (obj.text_align != null) clean.text_align = obj.text_align;
  if (obj.size_scale != null && typeof obj.size_scale === "object" && !Array.isArray(obj.size_scale)) {
    const ss = {};
    for (const k of SIZE_KEYS) if (typeof obj.size_scale[k] === "number") ss[k] = obj.size_scale[k];
    if (Object.keys(ss).length) clean.size_scale = ss;
  }
  if (Array.isArray(obj.element_order)) {
    clean.element_order = obj.element_order.filter((t) => ORDER_TOKENS.includes(t));
  }
  return isValidSpec(clean) ? clean : null;
}

// Theme-preset tokens, mirroring lib/theme.ts PRESETS and brand_kit_defaults.
const PRESET_TOKENS = {
  warm: { surface: "#FFFFFF", paper: "#FAFAF7", ink: "#14170E", ink2: "#57534E" },
  clean: { surface: "#FFFFFF", paper: "#FFFFFF", ink: "#0A0A0A", ink2: "#404040" },
  calm: { surface: "#FBFCFB", paper: "#F2F5F2", ink: "#1A211A", ink2: "#4A554A" },
  bold: { surface: "#16181A", paper: "#0E1012", ink: "#F5F5F4", ink2: "#C4C4C2" },
};

/** The studio defaults: accent + preset tokens, Space Grotesk, list layout. */
export function defaultSpec({ accent, themePreset } = {}) {
  const t = PRESET_TOKENS[themePreset] || PRESET_TOKENS.warm;
  return {
    colors: {
      background: t.paper, surface: t.surface, ink: t.ink,
      accent: typeof accent === "string" && HEX6.test(accent) ? accent : "#78716C",
      secondary: t.ink2,
    },
    display_font: "Space Grotesk", body_font: "Space Grotesk",
    layout: "list", radius: "small", tone: "Clean, calm and legible.",
    logo_placement: "top-left", background_treatment: "none",
  };
}
