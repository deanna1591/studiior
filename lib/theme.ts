/**
 * Studio theming for the member PWA.
 *
 * Four presets, each a complete surface system rather than a colour swap: a
 * preset defines the same six tokens, so nothing downstream ever asks which
 * one is active. Every value below was measured before it was allowed in, and
 * the floor is the same one the staff app uses — muted text clears 4.5:1 on
 * BOTH the surface and the paper behind it.
 *
 * Calm's obvious sage grey (#6E796E) missed at 4.14 on its own paper. It is
 * darkened 10% toward its ink to #667066 (4.69 / 5.01) rather than being
 * shipped as a near-miss, which is the same call as coral not setting body
 * text in the staff app.
 *
 * The staff app is not themed. Studiior's lime stays there: a studio brands
 * what its members see, not its own back office.
 */
export const PRESETS = {
  warm: {
    label: "Warm",
    blurb: "Cream surfaces and soft contrast. The default, and the least tiring to read for a long time.",
    surface: "#FFFFFF", paper: "#FAFAF7",
    ink: "#14170E", ink2: "#57534E", ink3: "#78716C", line: "#E7E5E4",
  },
  clean: {
    label: "Clean",
    blurb: "Pure white, crisp hairlines, the highest contrast of the four.",
    surface: "#FFFFFF", paper: "#FFFFFF",
    ink: "#0A0A0A", ink2: "#404040", ink3: "#666666", line: "#E5E5E5",
  },
  calm: {
    label: "Calm",
    blurb: "Muted sage. Quiet and low contrast, without dropping below what is readable.",
    surface: "#FBFCFB", paper: "#F2F5F2",
    ink: "#1A211A", ink2: "#4A554A", ink3: "#667066", line: "#DDE4DD",
  },
  bold: {
    label: "Bold",
    blurb: "Near-black surfaces and light text. Reads well in a dim studio at 6am.",
    surface: "#16181A", paper: "#0E1012",
    ink: "#F5F5F4", ink2: "#C4C4C2", ink3: "#9A9A98", line: "#2A2D30",
  },
} as const;

export type PresetKey = keyof typeof PRESETS;
export const PRESET_KEYS = Object.keys(PRESETS) as PresetKey[];

/* --- colour maths ---------------------------------------------------------- */

function srgb(c: number) {
  const s = c / 255;
  return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
}
export function luminance(hex: string): number {
  const h = hex.replace("#", "");
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16));
  return 0.2126 * srgb(r) + 0.7152 * srgb(g) + 0.0722 * srgb(b);
}
export function contrast(a: string, b: string): number {
  const [la, lb] = [luminance(a), luminance(b)];
  const [hi, lo] = la > lb ? [la, lb] : [lb, la];
  return (hi + 0.05) / (lo + 0.05);
}
export function mix(fg: string, bg: string, amount: number): string {
  const [f, g] = [fg.replace("#", ""), bg.replace("#", "")];
  let out = "#";
  for (const i of [0, 2, 4]) {
    const v = Math.round(
      parseInt(f.slice(i, i + 2), 16) * amount + parseInt(g.slice(i, i + 2), 16) * (1 - amount),
    );
    out += v.toString(16).padStart(2, "0").toUpperCase();
  }
  return out;
}
export function isHex(v: string): boolean {
  return /^#[0-9a-fA-F]{6}$/.test(v.trim());
}

export type AccentRamp = {
  /** As chosen. Large fills only — it has not been asked to carry text. */
  fill: string;
  /** Darkened (or lightened, on a dark preset) until it clears 4.5:1 on the surface. */
  text: string;
  /** 12% over the surface, for a quiet background. */
  tint: string;
  /** What `text` actually measures on the surface. */
  textContrast: number;
  /** True when no amount of darkening got there and ink is used instead. */
  fellBack: boolean;
};

/**
 * Derive a usable ramp from one hex, the same way `--amber-deep` was derived:
 * step the hue toward the preset's ink until the result clears 4.5:1, and stop
 * at the first value that does — so the accent stays as close to what the
 * studio picked as legibility allows.
 *
 * When nothing works — a pale yellow on Warm cannot make readable text at any
 * darkness that still reads as that yellow — this returns the preset's ink and
 * says so, and the picker shows exactly that rather than silently substituting.
 */
export function accentRamp(accent: string, preset: PresetKey): AccentRamp {
  const p = PRESETS[preset];
  const fill = isHex(accent) ? accent.trim().toUpperCase() : "#BEF738";

  // Capped at 60% toward ink. Past that it is not the studio's colour any
  // more, it is ink wearing a hint of it — and quietly shipping that is the
  // silent substitution this is supposed to avoid. Stopping here is what makes
  // `fellBack` a real answer the picker can show rather than dead code.
  let text = fill;
  for (let step = 0; step <= 15; step++) {
    const candidate = mix(p.ink, fill, step * 0.04);
    if (contrast(candidate, p.surface) >= 4.5) {
      text = candidate;
      return {
        fill,
        text,
        tint: mix(fill, p.surface, 0.12),
        textContrast: Math.round(contrast(candidate, p.surface) * 100) / 100,
        fellBack: false,
      };
    }
  }
  return {
    fill,
    text: p.ink,
    tint: mix(fill, p.surface, 0.12),
    textContrast: Math.round(contrast(p.ink, p.surface) * 100) / 100,
    fellBack: true,
  };
}

/** The custom properties the member app is themed with. */
export function themeVars(preset: PresetKey, accent: string): Record<string, string> {
  const p = PRESETS[preset];
  const a = accentRamp(accent, preset);
  return {
    "--surface": p.surface,
    "--paper": p.paper,
    "--ink": p.ink,
    "--ink-2": p.ink2,
    "--ink-3": p.ink3,
    "--line": p.line,
    "--line-2": mix(p.ink, p.line, 0.14),
    "--lime": a.fill,
    "--lime-tint": a.tint,
    "--lime-text": a.text,
    "--lime-text-2": a.text,
  };
}
