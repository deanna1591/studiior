// Types for the plain-ESM lib/email-preview-size.mjs (see lib/schedule-bounds.d.ts
// for why the runtime is .mjs and the types live in a sibling .d.ts).

/**
 * The preview iframe's layout width, scale and rendered box width for a column
 * of usable width `avail` px (<= 0 = not measured yet). Mobile reflows to
 * min(375, avail); desktop lays out at 600 and scales down to fit. boxW <= avail
 * always, so the preview never overflows its column.
 */
export function previewBox(args: {
  mode: "mobile" | "desktop";
  avail: number;
}): { renderW: number; scale: number; boxW: number };
