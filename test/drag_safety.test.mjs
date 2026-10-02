// Decision 42a amendment (c): the Day-view drag snap and time-change gate.
// Run: node --test test/drag_safety.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveDrag } from "../lib/drag-safety.mjs";

const T = (h, m = 0) => new Date(2026, 10, 11, h, m, 0).getTime(); // a fixed wall day

test("Day-view column change with no vertical move keeps the time (not a retime)", () => {
  const r = resolveDrag(T(7), T(7), { columnChanged: true, isDay: true, stepMin: 15 });
  assert.equal(r.snapped, true);
  assert.equal(r.timeChanged, false);
  assert.equal(r.startMs, T(7));
});

test("Day-view column change within one slot snaps back to the original time", () => {
  // 07:00 -> 07:10, slip of 10 min < one 15-min slot
  const r = resolveDrag(T(7, 0), T(7, 10), { columnChanged: true, isDay: true, stepMin: 15 });
  assert.equal(r.snapped, true);
  assert.equal(r.timeChanged, false);
  assert.equal(r.startMs, T(7, 0));
});

test("Day-view column change beyond one slot is a real retime (no snap, confirm)", () => {
  // 07:00 -> 18:00
  const r = resolveDrag(T(7), T(18), { columnChanged: true, isDay: true, stepMin: 15 });
  assert.equal(r.snapped, false);
  assert.equal(r.timeChanged, true);
  assert.equal(r.startMs, T(18));
});

test("exactly one slot is still a slip (snaps); one slot + a minute is a retime", () => {
  const slip = resolveDrag(T(7, 0), T(7, 15), { columnChanged: true, isDay: true, stepMin: 15 });
  assert.equal(slip.snapped, true);
  const retime = resolveDrag(T(7, 0), T(7, 16), { columnChanged: true, isDay: true, stepMin: 15 });
  assert.equal(retime.snapped, false);
  assert.equal(retime.timeChanged, true);
});

test("a same-column time change (no column change) is a retime, never snapped", () => {
  const r = resolveDrag(T(7), T(7, 30), { columnChanged: false, isDay: true, stepMin: 15 });
  assert.equal(r.snapped, false);
  assert.equal(r.timeChanged, true);
});

test("Week view never snaps — the column-slip rule is Day-view only", () => {
  const r = resolveDrag(T(7), T(7, 5), { columnChanged: true, isDay: false, stepMin: 15 });
  assert.equal(r.snapped, false);
  assert.equal(r.timeChanged, true); // 07:00 -> 07:05 in week view is a (small) retime
});

test("a pure time change with no column change and no movement is not a retime", () => {
  const r = resolveDrag(T(7), T(7), { columnChanged: false, isDay: true, stepMin: 15 });
  assert.equal(r.timeChanged, false);
});
