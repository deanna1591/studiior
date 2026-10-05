import { test } from "node:test";
import assert from "node:assert/strict";
import { clampInt, cutoffMinutes, cutoffParts, cutoffLabel } from "../lib/booking-rules.mjs";

test("clampInt floors a non-negative number, else the fallback", () => {
  assert.equal(clampInt("30", 7), 30);
  assert.equal(clampInt("12.9", 7), 12);
  // Preserved /welcome behaviour: empty/whitespace/null parse to 0 (Number("")
  // is 0, which is finite and >= 0), NOT the fallback. The fallback is only for
  // a non-finite or negative value.
  assert.equal(clampInt("", 7), 0);
  assert.equal(clampInt("   ", 7), 0);
  assert.equal(clampInt(null, 30), 0);
  assert.equal(clampInt(undefined, 7), 0);
  assert.equal(clampInt("-1", 7), 7);
  assert.equal(clampInt("abc", 7), 7);
});

test("cutoffMinutes composes hours + minutes into total minutes", () => {
  assert.equal(cutoffMinutes("12", "0"), 720);
  assert.equal(cutoffMinutes("12", "30"), 750);
  assert.equal(cutoffMinutes("0", "45"), 45);
  assert.equal(cutoffMinutes("", ""), 0);
});

test("cutoffParts splits a stored total", () => {
  assert.deepEqual(cutoffParts(720), { hours: 12, minutes: 0 });
  assert.deepEqual(cutoffParts(750), { hours: 12, minutes: 30 });
  assert.deepEqual(cutoffParts(45), { hours: 0, minutes: 45 });
  assert.deepEqual(cutoffParts(0), { hours: 0, minutes: 0 });
});

test("cutoffLabel reads 720 as '12 h'", () => {
  assert.equal(cutoffLabel(720), "12 h");
  assert.equal(cutoffLabel(750), "12 h 30 m");
  assert.equal(cutoffLabel(45), "45 m");
  assert.equal(cutoffLabel(0), "no cut-off");
});
