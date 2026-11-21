// Decision 100(a): the booking sheet shows studio time, the same as the roster.
import { test } from "node:test";
import assert from "node:assert/strict";
import { staffWhen } from "../lib/staff-when.mjs";
import { fmtClock } from "../lib/clock.mjs";

// 02:00 UTC is 10:00 in Manila (UTC+8, no DST).
const ISO = "2026-11-22T02:00:00Z";

test("the sheet reads the studio's 10:00 AM, not the viewer's clock", () => {
  assert.equal(staffWhen(ISO, "Asia/Manila", "12h"), "Sun 22 Nov, 10:00 AM");
});

test("its time equals the roster's string for the same instant (fmtTime = fmtClock)", () => {
  const rosterTime = fmtClock(ISO, "Asia/Manila", "12h"); // what the roster renders
  assert.equal(rosterTime, "10:00 AM");
  assert.ok(staffWhen(ISO, "Asia/Manila", "12h").endsWith(`, ${rosterTime}`));
});

test("24h studios read 24h, and the day follows the studio zone", () => {
  assert.equal(staffWhen(ISO, "Asia/Manila", "24h"), "Sun 22 Nov, 10:00");
  // Same instant in Los Angeles is still Saturday evening: the zone decides the day.
  assert.equal(staffWhen(ISO, "America/Los_Angeles", "12h"), "Sat 21 Nov, 6:00 PM");
});
