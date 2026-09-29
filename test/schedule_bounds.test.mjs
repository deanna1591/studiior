// Calendar day-view regression — the schedule grid's min/max bounds.
// Runs with zero deps:  node --test test/schedule_bounds.test.mjs
// (run-suites.sh is SQL; this is a standalone Node built-in test of the pure
// helpers behind react-big-calendar's min/max/date.)
//
// THE BUG THIS GUARDS: a studio open until 22:50 makes hourBounds return
// maxHour = 24, and the OLD wallAt did `new Date(y, m-1, d, 24, 0, 0)`, which
// JavaScript rolls to 00:00 of the NEXT day. rbc was then handed a `max` on a
// different calendar day than its `min`/`date` and collapsed every event to
// top:100% height:0% — one strip at the very bottom of the grid. Run this file
// against the old wallAt (return `new Date(y, m-1, d, hour, 0, 0, 0)` with no
// hour>=24 branch) and "22:50 keeps max on the same calendar day" goes RED.
import { test } from "node:test";
import assert from "node:assert/strict";
import { wallAt, hourBounds } from "../lib/schedule-bounds.mjs";

const ANCHOR = "2026-11-11"; // a Wednesday; the day in the bug report

test("a day ending at 22:50 yields maxHour 24", () => {
  // 09:00..22:50 in studio-local minutes.
  const starts = [540, 660, 780, 1020, 1080, 1140, 1320]; // 09:00 .. 22:00
  const ends = [590, 710, 830, 1070, 1130, 1190, 1370]; // .. 22:50
  const { minHour, maxHour } = hourBounds(starts, ends);
  assert.equal(maxHour, 24, "ceil(1370/60)+1 clamps to 24");
  assert.equal(minHour, 8, "floor(540/60)-1");
});

test("22:50 keeps max on the SAME calendar day as min and date (the regression)", () => {
  const { minHour, maxHour } = hourBounds([540], [1370]); // one 09:00–22:50 class
  const min = wallAt(ANCHOR, minHour);
  const max = wallAt(ANCHOR, maxHour); // maxHour === 24
  const date = wallAt(ANCHOR, 12);

  // All three must be the SAME calendar date. The old rollover put max on 11-12.
  assert.equal(max.getFullYear(), min.getFullYear());
  assert.equal(max.getMonth(), min.getMonth());
  assert.equal(max.getDate(), min.getDate(), "max must not roll onto the next day");
  assert.equal(max.getDate(), date.getDate(), "max shares the anchor day with date");
  assert.equal(max.getDate(), 11, "the anchor is the 11th, not the 12th");

  // ...and the bounds are non-degenerate: max strictly after min, still same day.
  assert.ok(max.getTime() > min.getTime(), "max > min");
  // End-of-day, not next-day-midnight.
  assert.equal(max.getHours(), 23);
  assert.equal(max.getMinutes(), 59);
});

test("a normal daytime schedule is unaffected (max is an exact hour, same day)", () => {
  // 09:00..19:50 — maxHour = ceil(1190/60)+1 = 21, well under 24.
  const { minHour, maxHour } = hourBounds([540], [1190]);
  assert.equal(maxHour, 21);
  const min = wallAt(ANCHOR, minHour);
  const max = wallAt(ANCHOR, maxHour);
  assert.equal(max.getDate(), min.getDate(), "same day");
  assert.equal(max.getHours(), 21, "an under-24 hour is left exact");
  assert.equal(max.getMinutes(), 0);
  assert.ok(max.getTime() > min.getTime());
});

test("an empty day falls back to 07:00–20:00, non-degenerate and same-day", () => {
  const { minHour, maxHour } = hourBounds([], []);
  assert.equal(minHour, 6); // floor(420/60)-1
  assert.equal(maxHour, 21); // ceil(1200/60)+1
  const min = wallAt(ANCHOR, minHour);
  const max = wallAt(ANCHOR, maxHour);
  assert.equal(max.getDate(), min.getDate());
  assert.ok(max.getTime() > min.getTime());
});

test("wallAt: hour >= 24 is end-of-same-day, under 24 is an exact hour", () => {
  assert.equal(wallAt(ANCHOR, 24).getDate(), 11);
  assert.equal(wallAt(ANCHOR, 24).getHours(), 23);
  assert.equal(wallAt(ANCHOR, 24).getMinutes(), 59);
  assert.equal(wallAt(ANCHOR, 20).getHours(), 20);
  assert.equal(wallAt(ANCHOR, 20).getDate(), 11);
});
