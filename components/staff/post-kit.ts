// Shared drawing pieces for the schedule-post styles (Decision 93): the brand
// tokens and the colour helpers. Used by components/staff/schedule-post.tsx and
// the v5 styles in components/staff/post-styles-v5.tsx.
import type { BrandSpec } from "@/lib/brand-kit";

export type Tokens = {
  background: string; surface: string; ink: string; accent: string; secondary: string;
  df: string; bf: string; mono: string; hand: string; onAccent: string;
};
export function tokens(spec: BrandSpec): Tokens {
  const c = spec.colors;
  return {
    background: c.background, surface: c.surface, ink: c.ink, accent: c.accent, secondary: c.secondary,
    df: `'${spec.display_font}', serif`, bf: `'${spec.body_font}', sans-serif`,
    mono: "'Space Mono', monospace", hand: "'Nothing You Could Do', cursive",
    onAccent: textOn(c.accent, c.ink),
  };
}
export function hex(h: string): [number, number, number] {
  const m = /^#?([0-9a-f]{6})$/i.exec(String(h || "").trim());
  if (!m) return [128, 128, 128];
  const n = parseInt(m[1], 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}
export function toHex([r, g, b]: [number, number, number]): string {
  return "#" + [r, g, b].map((v) => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, "0")).join("");
}
export function mixHex(a: string, b: string, t: number): string {
  const [ar, ag, ab] = hex(a), [br, bg, bb] = hex(b);
  return toHex([ar + (br - ar) * t, ag + (bg - ag) * t, ab + (bb - ab) * t]);
}
/** Readable text on an accent fill: dark ink when the accent is light, else white. */
export function textOn(accent: string, ink: string): string {
  const [r, g, b] = hex(accent);
  const y = (r * 299 + g * 587 + b * 114) / 1000;
  return y >= 150 ? ink : "#FFFFFF";
}
export function soft(hexColor: string, alpha: number): string {
  const [r, g, b] = hex(hexColor);
  return `rgba(${r},${g},${b},${alpha})`;
}

