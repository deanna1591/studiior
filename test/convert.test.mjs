import { test } from "node:test";
import assert from "node:assert/strict";
import {
  windowEndMs, windowActive, quietShift, daysSince,
  dateRuleDue, afterClassDue, viberText, CONVERT_TEMPLATES,
  keepRuleDue, KEEP_TEMPLATES, taskKindForBand, taskRecovered,
} from "../lib/convert.mjs";

const DAY = 86_400_000;

test("window end is N days after the free class", () => {
  const start = Date.parse("2026-11-01T02:00:00Z");
  assert.equal(windowEndMs(start, 14), start + 14 * DAY);
});

test("window active only inside [start,end) and not purchased", () => {
  const start = 1000, end = 1000 + 14 * DAY;
  assert.equal(windowActive(start, end, start + DAY, false), true);
  assert.equal(windowActive(start, end, start - 1, false), false);   // before
  assert.equal(windowActive(start, end, end, false), false);         // at end (exclusive)
  assert.equal(windowActive(start, end, start + DAY, true), false);  // purchased
  assert.equal(windowActive(null, end, start, false), false);        // no free class
});

test("quiet hours 21:00–08:00 shift to 08:00", () => {
  assert.deepEqual(quietShift(22), { hour: 8, dayDelta: 1 });
  assert.deepEqual(quietShift(21), { hour: 8, dayDelta: 1 });
  assert.deepEqual(quietShift(5),  { hour: 8, dayDelta: 0 });
  assert.deepEqual(quietShift(0),  { hour: 8, dayDelta: 0 });
  assert.deepEqual(quietShift(8),  { hour: 8, dayDelta: 0 });
  assert.deepEqual(quietShift(14), { hour: 14, dayDelta: 0 });
  assert.deepEqual(quietShift(20), { hour: 20, dayDelta: 0 });
});

test("daysSince is whole days, floored, never negative", () => {
  assert.equal(daysSince("2026-11-01", "2026-11-08"), 7);
  assert.equal(daysSince("2026-11-01", "2026-11-01"), 0);
  assert.equal(daysSince("2026-11-08", "2026-11-01"), 0);
});

test("date-anchored rules fire on their own day", () => {
  assert.equal(dateRuleDue("before_class", -1), true);
  assert.equal(dateRuleDue("before_class", 0), false);
  assert.equal(dateRuleDue("missed_you", 1), true);
  assert.equal(dateRuleDue("day3", 3), true);
  assert.equal(dateRuleDue("day3", 4), false);
  assert.equal(dateRuleDue("day7", 7), true);
  assert.equal(dateRuleDue("last_day", 7), false); // last_day is window-anchored, not date-delta
});

test("after_class is due from +2h to +26h", () => {
  const end = 1_000_000_000_000;
  assert.equal(afterClassDue(end, end + 2 * 3_600_000), true);
  assert.equal(afterClassDue(end, end + 1 * 3_600_000), false);
  assert.equal(afterClassDue(end, end + 27 * 3_600_000), false);
});

test("viber text carries the first name and offer, with fallbacks", () => {
  const t = viberText("Maria", "Reform", "Intro Pack");
  assert.match(t, /Hi Maria!/);
  assert.match(t, /Reform/);
  assert.match(t, /Intro Pack/);
  assert.match(viberText("", "Reform", null), /Hi there!/);
  assert.match(viberText("  ", "Reform", ""), /a membership/);
});

test("the convert template set is the six", () => {
  assert.equal(CONVERT_TEMPLATES.length, 6);
  assert.ok(CONVERT_TEMPLATES.includes("convert_before_class"));
  assert.ok(CONVERT_TEMPLATES.includes("convert_missed_you"));
});

test("keep rules fire on their own day relative to the membership end", () => {
  assert.equal(keepRuleDue("renew_7", -7), true);
  assert.equal(keepRuleDue("renew_7", -6), false);
  assert.equal(keepRuleDue("renew_1", -1), true);
  assert.equal(keepRuleDue("renew_0", 0), true);
  assert.equal(keepRuleDue("lapsed_3", 3), true);
  assert.equal(keepRuleDue("credits_7", -7), true);
  assert.equal(keepRuleDue("credits_2", -2), true);
  assert.equal(keepRuleDue("winback_30", 30), true);
  assert.equal(keepRuleDue("winback_60", 60), true);
  assert.equal(keepRuleDue("renew_0", 1), false);
  assert.equal(KEEP_TEMPLATES.length, 8);
});

test("task kind follows the health band", () => {
  assert.equal(taskKindForBand("at_risk"), "at_risk");
  assert.equal(taskKindForBand("drifting"), "drifting_fyi");
  assert.equal(taskKindForBand("healthy"), null);
  assert.equal(taskKindForBand("new"), null);
});

test("a task recovers on a healthy/new band or a check-in", () => {
  assert.equal(taskRecovered("healthy", false), true);
  assert.equal(taskRecovered("new", false), true);
  assert.equal(taskRecovered("at_risk", true), true);   // checked in since
  assert.equal(taskRecovered("at_risk", false), false);
  assert.equal(taskRecovered("drifting", false), false);
});
