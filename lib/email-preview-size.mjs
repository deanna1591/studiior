/**
 * The email preview's iframe size — pure, and testable with `node --test`.
 *
 * Kept in plain ESM (a sibling .d.ts types it for the app under
 * `moduleResolution: bundler`) so the exact rule the preview ships is the rule
 * the node test checks, rather than a second copy in a .ts Node 20 cannot import.
 * EmailPreview imports `previewBox` so there is ONE implementation.
 *
 * The rule (item 1): the preview NEVER overflows its column.
 *  - Mobile: the fluid email frame reflows to phone width, so the iframe's own
 *    width is min(375, column) — 375 normally, the column when it is narrower —
 *    at scale 1 (no clipping, no horizontal scroll).
 *  - Desktop: the iframe lays out at 600 and scales DOWN to the column when the
 *    column is narrower than 600 (as already built); at scale 1 otherwise.
 * In both cases the rendered box width is <= the column, so the page never
 * scrolls sideways. `avail` is the column's usable width (its clientWidth minus
 * the 16px padding each side); <= 0 means "not measured yet", so fall back to
 * the mode's natural width.
 */
export function previewBox({ mode, avail }) {
  const measured = typeof avail === "number" && avail > 0 ? avail : null;
  if (mode === "mobile") {
    const renderW = measured === null ? 375 : Math.min(375, measured);
    return { renderW, scale: 1, boxW: renderW };
  }
  // desktop
  const renderW = 600;
  const scale = measured !== null && measured < renderW ? measured / renderW : 1;
  return { renderW, scale, boxW: renderW * scale };
}
