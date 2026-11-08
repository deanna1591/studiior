import { test } from "node:test";
import assert from "node:assert/strict";
import {
  rangeFor, defaultDate, coreOnlyDefault, filterDays, captionText, monthCells, totalClasses, classLine,
} from "../lib/schedule-post.mjs";

// A fixed grouped sample, the shape schedule_post_data returns.
const DATA = {
  hashtags: "#reform #pilates",
  days: [
    { date: "2026-11-09", label: "Monday 09 Nov", count: 2, classes: [
      { time: "7:00 AM", name: "Reformer Flow", coach: "Ada", tier: "core" },
      { time: "6:00 PM", name: "Mat Pilates", coach: null, tier: "flex" },
    ] },
    { date: "2026-11-11", label: "Wednesday 11 Nov", count: 1, classes: [
      { time: "7:00 AM", name: "Reformer Burn", coach: "Mia", tier: "core" },
    ] },
  ],
};

test("rangeFor: day, week (Mon-based), month", () => {
  assert.deepEqual(rangeFor("day", "2026-11-09"), { from: "2026-11-09", to: "2026-11-09" });
  // 2026-11-11 is a Wednesday -> Mon 9th .. Sun 15th
  assert.deepEqual(rangeFor("week", "2026-11-11"), { from: "2026-11-09", to: "2026-11-15" });
  assert.deepEqual(rangeFor("month", "2026-11-20"), { from: "2026-11-01", to: "2026-11-30" });
  // Feb (leap-safe): 2027 is not a leap year -> 28 days
  assert.deepEqual(rangeFor("month", "2027-02-10"), { from: "2027-02-01", to: "2027-02-28" });
});

test("defaultDate: tomorrow / next Monday / first of next month", () => {
  assert.equal(defaultDate("day", "2026-11-07"), "2026-11-08");
  // 2026-11-07 is a Saturday; this week's Monday is the 2nd; next Monday the 9th
  assert.equal(defaultDate("week", "2026-11-07"), "2026-11-09");
  assert.equal(defaultDate("month", "2026-11-07"), "2026-12-01");
  assert.equal(defaultDate("month", "2026-12-20"), "2027-01-01");
});

test("coreOnlyDefault: on while the flex minimum is above 1", () => {
  assert.equal(coreOnlyDefault(1), false);
  assert.equal(coreOnlyDefault(2), true);
  assert.equal(coreOnlyDefault(0), false);
});

test("filterDays: core-only drops flex classes and empty days", () => {
  const all = filterDays(DATA.days, false);
  assert.equal(totalClasses(all), 3);
  const core = filterDays(DATA.days, true);
  assert.equal(totalClasses(core), 2);                       // the flex Mat Pilates is gone
  assert.equal(core[0].classes.length, 1);
  assert.equal(core[0].count, 1);                            // count recomputed
  assert.equal(core.every((d) => d.classes.every((c) => c.tier === "core")), true);
  // a day left with no core class is dropped
  const onlyFlexDay = filterDays([{ date: "x", label: "X", count: 1, classes: [{ time: "9", name: "Y", coach: null, tier: "flex" }] }], true);
  assert.equal(onlyFlexDay.length, 0);
});

test("grouping: caption keeps classes under their day label, in order", () => {
  const cap = captionText(DATA);
  const lines = cap.split("\n");
  assert.equal(lines[0], "Monday 09 Nov");
  assert.equal(lines[1], "7:00 AM Reformer Flow — Ada");
  assert.equal(lines[2], "6:00 PM Mat Pilates");            // no coach -> no dash
  assert.equal(lines[3], "");                                // blank line between days
  assert.equal(lines[4], "Wednesday 11 Nov");
  assert.equal(lines[5], "7:00 AM Reformer Burn — Mia");
  assert.equal(lines[lines.length - 1], "#reform #pilates"); // hashtags last
});

test("caption text: empty days -> just the hashtags, or empty", () => {
  assert.equal(captionText({ days: [], hashtags: "#x" }), "#x");
  assert.equal(captionText({ days: [], hashtags: "" }), "");
  assert.equal(captionText({ days: [], hashtags: null }), "");
  assert.equal(classLine({ time: "7:00 AM", name: "Flow", coach: null }), "7:00 AM Flow");
});

test("month summary: a cell per day, count + first three + more", () => {
  const many = {
    days: [{ date: "2026-11-09", label: "Monday 09 Nov", count: 4, classes: [
      { time: "7", name: "A", coach: null, tier: "core" },
      { time: "8", name: "B", coach: null, tier: "core" },
      { time: "9", name: "C", coach: null, tier: "core" },
      { time: "10", name: "D", coach: null, tier: "core" },
    ] }],
  };
  const cells = monthCells(many.days, 3);
  assert.equal(cells.length, 1);
  assert.deepEqual(cells[0].first, ["A", "B", "C"]);
  assert.equal(cells[0].count, 4);
  assert.equal(cells[0].more, 1);
  // a day with no classes is not a cell
  assert.equal(monthCells([{ date: "x", label: "X", count: 0, classes: [] }]).length, 0);
});
