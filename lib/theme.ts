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

/**
 * Nudge a colour round the wheel, keeping its lightness and saturation.
 *
 * The page gradient needs a second stop that is recognisably the same colour
 * and not the same value — the mockup's terracotta wash drifts a whisper
 * toward violet on the way down. Rotating the hue does that for ANY accent,
 * where a hand-picked second hex would only ever have worked for terracotta.
 *
 * NEGATIVE, and measured against the mockup: terracotta sits at hue 18, and
 * its second stop #F2E6F0 is up at 310. Rotating +25 went the other way, into
 * orange, and the gradient came out warmer at the bottom than the top —
 * the opposite of what the mockup does and, at equal lightness, invisible.
 */
export function rotateHue(hex: string, degrees: number): string {
  const h = hex.replace("#", "");
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16) / 255);
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  const l = (max + min) / 2;
  const d = max - min;
  if (d === 0) return hex.toUpperCase();
  const sat = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  let hue =
    max === r ? ((g - b) / d + (g < b ? 6 : 0))
    : max === g ? (b - r) / d + 2
    : (r - g) / d + 4;
  hue = ((hue * 60 + degrees) % 360 + 360) % 360;

  const c = (1 - Math.abs(2 * l - 1)) * sat;
  const x = c * (1 - Math.abs(((hue / 60) % 2) - 1));
  const m = l - c / 2;
  const [rr, gg, bb] =
    hue < 60 ? [c, x, 0] : hue < 120 ? [x, c, 0] : hue < 180 ? [0, c, x]
    : hue < 240 ? [0, x, c] : hue < 300 ? [x, 0, c] : [c, 0, x];
  return "#" + [rr, gg, bb]
    .map((v) => Math.round((v + m) * 255).toString(16).padStart(2, "0").toUpperCase())
    .join("");
}

export type AccentRamp = {
  /** As chosen. Large fills only — it has not been asked to carry text. */
  fill: string;
  /** Darkened (or lightened, on a dark preset) until it clears 4.5:1 on the surface. */
  text: string;
  /** 12% over the surface, for a quiet background — chips, active nav. */
  tint: string;
  /**
   * 3.5% over the surface. A card ground that is warm on a terracotta studio
   * and cool on a navy one, without being a colour anybody would name — pure
   * white cards on a pure white page are why the app read as a document.
   *
   * 3.5 and not 4: at 4% a deep purple on Warm takes --ink-3 to 4.47, and
   * --ink-3 IS the muted floor (4.59 on plain white). A background tint that
   * costs a fifth of a point of contrast on every secondary line in the app is
   * not a background tint worth having. Measured across 32 combinations, the
   * worst at 3.5% is 4.51.
   */
  wash: string;
  /** 14% over the surface, for the square behind an icon. */
  chip: string;
  /**
   * The page itself. Two stops: the accent over the surface, and the same
   * accent rotated a little round the wheel so the gradient has somewhere to
   * go. White cards float on this — the single change that stops the app
   * reading as a document, because a white card on a cream page has nothing to
   * separate it from the page.
   */
  washTop: string;
  washBottom: string;
  /** What `text` actually measures on the surface. */
  textContrast: number;
  /** True when no amount of darkening got there and ink is used instead. */
  fellBack: boolean;
  /**
   * The accent as a FILLED surface — a primary button, the today circle in the
   * week strip, the active tab's pip. Usually the accent as chosen; adjusted
   * only when neither ink nor the surface colour could sit on it legibly.
   */
  solid: string;
  /** The text colour that sits ON `solid`. Measured, never assumed. */
  onSolid: string;
  /** What `onSolid` measures on `solid`. */
  onSolidContrast: number;
  /** True when `solid` had to move off the studio's chosen hex to stay legible. */
  solidAdjusted: boolean;
};

/**
 * What can legibly sit on a filled patch of `candidate`.
 *
 * The existing ramp answers "accent as text on our surface". A filled button
 * asks the opposite question and the answer is not the same: #BEF738 carries
 * near-black happily and white not at all, and a deep terracotta is the other
 * way round. Nothing in the app may hard-code one — a studio picking a mid
 * green would get 2.9:1 either way and a button nobody can read.
 */
function bestOn(candidate: string, p: (typeof PRESETS)[PresetKey]) {
  const onInk = contrast(p.ink, candidate);
  const onSurface = contrast(p.surface, candidate);
  return onInk >= onSurface
    ? { colour: p.ink, ratio: onInk }
    : { colour: p.surface, ratio: onSurface };
}

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
/**
 * What a studio that has chosen no accent gets.
 *
 * Its own preset's ink, not #BEF738. Studiior's lime is Studiior's, and
 * defaulting to it put our brand colour on the login screen, the today circle
 * and every primary button of every studio that had not picked a colour yet —
 * which is all of them on day one. Migration 034 already made this call for
 * email, where the accent rule falls back to neutral grey rather than to lime;
 * this is the same rule for the app. A monochrome member app is a deliberate
 * look. Somebody else's brand is not.
 */
export function neutralAccent(preset: PresetKey): string {
  return PRESETS[preset].ink;
}

export function accentRamp(accent: string, preset: PresetKey): AccentRamp {
  const p = PRESETS[preset];
  const fill = isHex(accent) ? accent.trim().toUpperCase() : neutralAccent(preset);

  // Capped at 60% toward ink. Past that it is not the studio's colour any
  // more, it is ink wearing a hint of it — and quietly shipping that is the
  // silent substitution this is supposed to avoid. Stopping here is what makes
  // `fellBack` a real answer the picker can show rather than dead code.
  //
  // Measured against the PAGE WASH as well as the surface. Accent text used to
  // appear only inside white cards, so clearing 4.5 on --surface was the whole
  // requirement. The wash put the same colour on a tinted page — "See all"
  // landed at 4.21 — and a step that is safe on one and not the other is worse
  // than no step, because nothing at the call site says which ground it is on.
  const washFloor = mix(rotateHue(fill, -45), p.surface, 0.10);
  let text = fill;
  for (let step = 0; step <= 15; step++) {
    const candidate = mix(p.ink, fill, step * 0.04);
    if (contrast(candidate, p.surface) >= 4.5 && contrast(candidate, washFloor) >= 4.5) {
      text = candidate;
      return {
        fill,
        text,
        tint: mix(fill, p.surface, 0.12),
        wash: mix(fill, p.surface, 0.035),
        chip: mix(fill, p.surface, 0.14),
        washTop: mix(fill, p.surface, 0.06),
        washBottom: mix(rotateHue(fill, -45), p.surface, 0.10),
        textContrast: Math.round(contrast(candidate, p.surface) * 100) / 100,
        fellBack: false,
        ...solidFor(fill, p),
      };
    }
  }
  return {
    fill,
    text: p.ink,
    tint: mix(fill, p.surface, 0.12),
    wash: mix(fill, p.surface, 0.035),
    chip: mix(fill, p.surface, 0.14),
    washTop: mix(fill, p.surface, 0.06),
    washBottom: mix(rotateHue(fill, -45), p.surface, 0.10),
    textContrast: Math.round(contrast(p.ink, p.surface) * 100) / 100,
    fellBack: true,
    ...solidFor(fill, p),
  };
}

/**
 * The filled-accent pair.
 *
 * Try the studio's colour as it is. If neither ink nor surface clears 4.5:1 on
 * it, walk it in whichever direction is already winning — darker to carry the
 * light text, lighter to carry the dark — and stop at the first value that
 * passes. Capped at 60% like the text ramp, and for the same reason: past that
 * it stops being their colour.
 */
function solidFor(fill: string, p: (typeof PRESETS)[PresetKey]) {
  const asIs = bestOn(fill, p);
  if (asIs.ratio >= 4.5) {
    return {
      solid: fill,
      onSolid: asIs.colour,
      onSolidContrast: Math.round(asIs.ratio * 100) / 100,
      solidAdjusted: false,
    };
  }

  // Which way to walk: toward ink if light text is closer, toward the surface
  // if dark text is. Moving the wrong way makes both worse.
  const toward = contrast(p.surface, fill) >= contrast(p.ink, fill) ? p.ink : p.surface;
  for (let step = 1; step <= 15; step++) {
    const candidate = mix(toward, fill, step * 0.04);
    const best = bestOn(candidate, p);
    if (best.ratio >= 4.5) {
      return {
        solid: candidate,
        onSolid: best.colour,
        onSolidContrast: Math.round(best.ratio * 100) / 100,
        solidAdjusted: true,
      };
    }
  }

  // Nothing in range. Ink is a surface every preset's own surface reads on.
  const last = bestOn(p.ink, p);
  return {
    solid: p.ink,
    onSolid: last.colour,
    onSolidContrast: Math.round(last.ratio * 100) / 100,
    solidAdjusted: true,
  };
}

/**
 * The login screen's accent field, as two stops that can both carry `onSolid`.
 *
 * The obvious version — accent at the top, accent darkened toward ink at the
 * bottom — is wrong on Bold, whose ink is nearly white: "darkening" lightens
 * the accent there and white text on it fell to 3.27. The second stop
 * therefore moves AWAY from the text colour rather than toward the preset's
 * ink, which can only ever increase the contrast the first stop was measured
 * for.
 */
export function accentGradient(ramp: AccentRamp): [string, string] {
  const away = luminance(ramp.onSolid) > 0.4 ? "#000000" : "#FFFFFF";
  return [ramp.solid, mix(away, ramp.solid, 0.18)];
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
    // The filled-accent pair. Named for what they are rather than borrowing
    // the lime names: these two are always used together and a caller that
    // takes one without the other has made a button nobody can read.
    "--accent-solid": a.solid,
    "--accent-on-solid": a.onSolid,
    "--accent-wash": a.wash,
    "--accent-chip": a.chip,
    // The page itself, as two stops. White cards float on this.
    "--page-top": a.washTop,
    "--page-bottom": a.washBottom,
  };
}
