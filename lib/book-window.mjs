// Decision 55 amendment (b): the Book page loads one detailed window spanning the
// whole visible strip (or month grid) forward to the published horizon, capped at
// 120 days, and builds a bundle for every day in it. These pure helpers decide the
// window length and its offsets so the bundle builder and the client agree, and so
// a node test can prove the window covers every day of the loaded range.

export const LOAD_CAP = 120;

/** How many days of detail to load. Week view loads the whole strip and a little
 *  past it (up to the cap); month view loads exactly the displayed grid. */
export function loadLen(monthView, gridLength, stripLen = 84) {
  return Math.min(LOAD_CAP, monthView ? gridLength : stripLen + 36);
}

/** The day offsets the window covers, contiguous from the grid's first day. */
export function windowOffsets(gridFromOffset, len) {
  return Array.from({ length: len }, (_, i) => gridFromOffset + i);
}

/** Does `offsets` cover every integer day from `from` to `to` inclusive. */
export function covers(offsets, from, to) {
  const s = new Set(offsets);
  for (let o = from; o <= to; o++) if (!s.has(o)) return false;
  return true;
}
