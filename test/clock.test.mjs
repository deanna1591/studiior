// Decision 55 — the per-tenant clock formatter (lib/clock.mjs), the TS mirror of
// the SQL fmt_clock(). Runs with zero deps:  node --test test/clock.test.mjs
//
// It must agree with fmt_clock() in supabase/migrations/20260832130000:
//   24h  -> "13:00"   (zero-padded, no meridiem)
//   12h  -> "1:00 PM" (midnight "12:00 AM", noon "12:00 PM", "9:05 AM")
// and the edges (midnight/noon) are the ones most easily got wrong.
import { test } from "node:test";
import assert from "node:assert/strict";
import { fmtClock } from "../lib/clock.mjs";

const UTC = "UTC";
const iso = (hhmm) => `2026-01-01T${hhmm}:00Z`;

test("24h renders a zero-padded zoneless clock, no meridiem", () => {
  assert.equal(fmtClock(iso("13:00"), UTC, "24h"), "13:00");
  assert.equal(fmtClock(iso("00:00"), UTC, "24h"), "00:00");
  assert.equal(fmtClock(iso("09:05"), UTC, "24h"), "09:05");
  assert.equal(fmtClock(iso("23:59"), UTC, "24h"), "23:59");
});

test("12h renders a meridiem clock", () => {
  assert.equal(fmtClock(iso("13:00"), UTC, "12h"), "1:00 PM");
  assert.equal(fmtClock(iso("09:05"), UTC, "12h"), "9:05 AM");
});

test("12h midnight is 12:00 AM and noon is 12:00 PM (not 0:00 / 0:00 PM)", () => {
  assert.equal(fmtClock(iso("00:00"), UTC, "12h"), "12:00 AM");
  assert.equal(fmtClock(iso("12:00"), UTC, "12h"), "12:00 PM");
});

test("the default format is 24h", () => {
  assert.equal(fmtClock(iso("13:00"), UTC), "13:00");
});

test("the studio timezone decides the clock, not the server/browser", () => {
  // 23:00 UTC is 07:00 the next morning in Manila.
  assert.equal(fmtClock("2026-01-01T23:00:00Z", "Asia/Manila", "24h"), "07:00");
  assert.equal(fmtClock("2026-01-01T23:00:00Z", "Asia/Manila", "12h"), "7:00 AM");
});

test("a Date instant formats the same as its ISO string", () => {
  const d = new Date("2026-01-01T13:00:00Z");
  assert.equal(fmtClock(d, UTC, "12h"), "1:00 PM");
});

test("minutes-of-day is a zoneless label (the calendar gutter)", () => {
  assert.equal(fmtClock(0, UTC, "24h"), "00:00");
  assert.equal(fmtClock(13 * 60, UTC, "24h"), "13:00");
  assert.equal(fmtClock(0, UTC, "12h"), "12:00 AM");
  assert.equal(fmtClock(12 * 60, UTC, "12h"), "12:00 PM");
  assert.equal(fmtClock(13 * 60 + 5, UTC, "12h"), "1:05 PM");
});
