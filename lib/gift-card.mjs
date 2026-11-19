// Decision 110 amendment (a) — the gift card's amount rule and the composited
// card layout (node-tested). The /giftcard route renders the layout with
// next/og; the SQL gift_card_begin enforces the same amount rule.

/** A custom gift amount: whole hundreds (in major units), at least the minimum. */
export function giftAmountProblem(cents, minCents = 50000) {
  if (!Number.isFinite(cents) || cents <= 0) return "Choose an amount.";
  if (cents < minCents) return `The smallest gift card is ${Math.round(minCents / 100).toLocaleString("en-US")}.`;
  if (cents % 10000 !== 0) return "Choose an amount in whole hundreds.";
  return null;
}

/** A gift code is {PREFIX}-XXXX-XXXX from the unambiguous alphabet (no 0 O 1 I). */
export function isGiftCode(code) {
  return /^[A-Z]{2,8}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/.test(String(code ?? ""));
}

function hexToRgb(hex) {
  const m = /^#?([0-9a-f]{6})$/i.exec(String(hex ?? "").trim());
  if (!m) return null;
  const n = parseInt(m[1], 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}
function lum([r, g, b]) {
  const f = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
  return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
}
export function contrastRatio(a, b) {
  const la = lum(hexToRgb(a)), lb = lum(hexToRgb(b));
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

/**
 * The composited card. With an uploaded studio card the text sits on a dark
 * scrim band at the bottom (white, measured against the band, never the photo).
 * Without one the default card is the studio accent with whichever of near-black
 * or white reads at 4.5:1 on it. Size is 1200x750 (a 16:10 card).
 */
export function cardLayout({ accent, hasImage }) {
  const base = hexToRgb(accent) ? accent : "#57534E";
  const dark = "#14170E", light = "#FFFFFF";
  const ink = contrastRatio(base, dark) >= contrastRatio(base, light) ? dark : light;
  return {
    width: 1200, height: 750,
    background: hasImage ? null : base,
    band: hasImage ? "rgba(20,23,14,0.78)" : null,
    ink: hasImage ? light : ink,
    inkContrast: Math.round((hasImage ? 9.9 : contrastRatio(base, ink)) * 100) / 100,
  };
}

// The card's typeface. next/og's built-in font has no ₱ (U+20B1), so the card
// drew the peso sign as an empty box. Space Grotesk (static TTFs already
// vendored for the invoice, SIL OFL) carries it. The route loads these from
// public/fonts/invoice (bundled via outputFileTracingIncludes, else the CDN).
export const GIFT_CARD_FONT_FAMILY = "Space Grotesk";
export const GIFT_CARD_FONTS = [
  { file: "SpaceGrotesk-Regular.ttf", weight: 400 },
  { file: "SpaceGrotesk-Medium.ttf", weight: 500 },
  { file: "SpaceGrotesk-Bold.ttf", weight: 700 },
];

// The amount as drawn on the card. With the card font loaded it is the studio's
// money format (₱2,000). Without it (a font that failed to load) the symbol is
// replaced by the ISO code, so the card never shows an empty glyph box.
export function cardAmountLabel(formatted, currency, fontLoaded) {
  if (fontLoaded) return formatted;
  return String(formatted).replace(/[^\d.,\s-]+/g, "").trim() + " " + currency;
}
