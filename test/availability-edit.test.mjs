// Decision 18(c)/(d): change lines and labels, mirroring SQL availability_change_lines.
// Run: node --test test/availability-edit.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { changeLines, lineText, linesFromWeek, outsideWarning, lineError } from "../lib/availability-edit.mjs";

test("the recorded examples, weekdays Monday first then dates", () => {
  const before = [{ day: 2, from: "09:00", to: "20:00" }, { day: 4, from: "09:00", to: "20:00" }];
  const after = [{ day: 2, from: "10:00", to: "20:00" }, { day: 3, from: "09:00", to: "12:00" },
    { date: "2026-12-14", from: "08:00", to: "15:00" }, { date: "2026-12-18", unavailable: true }];
  assert.deepEqual(changeLines(before, after), [
    "Tue 09:00 to 20:00 is now 10:00 to 20:00",
    "Wed 09:00 to 12:00 added",
    "Thu 09:00 to 20:00 removed",
    "Mon 14 Dec 08:00 to 15:00 added",
    "Fri 18 Dec not available added",
  ]);
});

test("Sunday sorts last among weekdays; unchanged lines say nothing", () => {
  const b = [{ day: 0, from: "09:00", to: "12:00" }, { day: 1, from: "09:00", to: "12:00" }];
  const a = [{ day: 0, from: "10:00", to: "12:00" }, { day: 1, from: "9:00", to: "12:00" }];
  assert.deepEqual(changeLines(b, a), ["Sun 09:00 to 12:00 is now 10:00 to 12:00"]);
  assert.deepEqual(changeLines(b, b), []);
});

test("two ranges on one day read as one comma list", () => {
  const b = [{ day: 1, from: "07:00", to: "10:00" }];
  const a = [{ day: 1, from: "17:00", to: "20:00" }, { day: 1, from: "07:00", to: "10:00" }];
  assert.deepEqual(changeLines(b, a), ["Mon 07:00 to 10:00 is now 07:00 to 10:00, 17:00 to 20:00"]);
});

test("a date marked off, then given hours", () => {
  assert.deepEqual(changeLines([{ date: "2026-12-14", unavailable: true }], [{ date: "2026-12-14", from: "08:00", to: "15:00" }]),
    ["Mon 14 Dec not available is now 08:00 to 15:00"]);
});

test("lineText, linesFromWeek, the warning and validation", () => {
  assert.equal(lineText({ day: 2, from: "09:00", to: "20:00" }), "Tue 09:00 to 20:00");
  assert.equal(lineText({ date: "2026-12-14", from: "08:00", to: "15:00" }), "Mon 14 Dec 08:00 to 15:00");
  const lines = linesFromWeek({ days: [{ day: 0, ranges: [{ from: "09:00", to: "12:00" }] }, { day: 2, ranges: [{ from: "09:00", to: "20:00" }] }],
    dates: [{ date: "2026-12-18", unavailable: true }] });
  assert.deepEqual(lines.map(lineText), ["Tue 09:00 to 20:00", "Sun 09:00 to 12:00", "Fri 18 Dec not available"]);
  assert.equal(outsideWarning("Ada", 3), "Ada is assigned to 3 classes in these hours. The assignments stay; reassign them from the Schedule.");
  assert.equal(outsideWarning("Ada", 1), "Ada is assigned to 1 class in these hours. The assignments stay; reassign them from the Schedule.");
  assert.equal(outsideWarning("Ada", 0), null);
  assert.equal(lineError({ day: 1, from: "10:00", to: "09:00" }), "A time must end after it starts.");
  assert.equal(lineError({ date: "2027-01-02", from: "09:00", to: "10:00" }, "2026-12-01", "2026-12-31"), "That date is after this month.");
  assert.equal(lineError({ date: "2026-12-14", unavailable: true }, "2026-12-01", "2026-12-31"), null);
});
