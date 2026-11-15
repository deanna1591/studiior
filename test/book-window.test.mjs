import { test } from "node:test";
import assert from "node:assert/strict";
import { LOAD_CAP, loadLen, windowOffsets, covers } from "../lib/book-window.mjs";

test("loadLen caps at 120 and spans the strip in week view", () => {
  assert.equal(LOAD_CAP, 120);
  // week view: strip (84) plus a little, capped at 120
  assert.equal(loadLen(false, 84, 84), 120);
  // a huge strip is still capped
  assert.equal(loadLen(false, 999, 200), 120);
  // month view loads exactly the grid
  assert.equal(loadLen(true, 42, 84), 42);
  assert.equal(loadLen(true, 35, 84), 35);
});

test("windowOffsets is contiguous from the grid's first day", () => {
  const offs = windowOffsets(-28, loadLen(false, 84, 84));
  assert.equal(offs.length, 120);
  assert.equal(offs[0], -28);
  assert.equal(offs[offs.length - 1], -28 + 119);
});

test("the bundle window covers EVERY day of the loaded range (week and month)", () => {
  // week view from the strip's first day (today - 28)
  const wOffs = windowOffsets(-28, loadLen(false, 84, 84));
  assert.ok(covers(wOffs, -28, -28 + loadLen(false, 84, 84) - 1), "every week-window day covered");
  // and specifically every strip day (today-28 .. today+55) is in the window
  assert.ok(covers(wOffs, -28, 55), "the whole 84-day strip is in the loaded window");

  // month view from the month block's first cell
  const mFrom = -3; // a leading-days offset
  const mOffs = windowOffsets(mFrom, loadLen(true, 42, 84));
  assert.ok(covers(mOffs, mFrom, mFrom + 41), "every month-grid cell is in the loaded window");
});

test("covers returns false when a day is missing", () => {
  assert.equal(covers([0, 1, 3], 0, 3), false);
  assert.equal(covers([0, 1, 2, 3], 0, 3), true);
});
