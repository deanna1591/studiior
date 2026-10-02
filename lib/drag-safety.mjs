// Decision 42a amendment (c): the drag-safety decision, extracted pure so it
// has a node test (this project has no JS test runner for .ts / React, but runs
// `node --test` over plain .mjs). Given a drop's start instant and the class's
// original start, decide whether the drop should keep the original time (a
// sub-slot vertical slip while changing instructor column, Day view only) and
// whether the resulting move changes the time at all (which the caller must
// confirm). Works on epoch milliseconds, timezone-agnostic — the caller passes
// studio-wall instants, which is all the comparison needs.

/**
 * @param {number} origStartMs  the class's current start (wall) in ms
 * @param {number} dropStartMs  where the drag dropped it (wall) in ms
 * @param {{columnChanged:boolean, isDay:boolean, stepMin:number}} opts
 * @returns {{startMs:number, snapped:boolean, timeChanged:boolean}}
 */
export function resolveDrag(origStartMs, dropStartMs, { columnChanged, isDay, stepMin }) {
  const slotMs = stepMin * 60_000;
  let startMs = dropStartMs;
  let snapped = false;
  // Day view: a column change that moved the start by no more than one full slot
  // is treated as a pure column change — the time is kept, so a slip between
  // instructor columns never retimes the class.
  if (isDay && columnChanged && Math.abs(dropStartMs - origStartMs) <= slotMs) {
    startMs = origStartMs;
    snapped = true;
  }
  return { startMs, snapped, timeChanged: startMs !== origStartMs };
}
