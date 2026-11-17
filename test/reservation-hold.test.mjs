import { test } from "node:test";
import assert from "node:assert/strict";
import { holdMinutesLeft, holdLabel, holdCountdownText, RESERVATION_HOLD_RETAP } from "../lib/reservation-hold.mjs";
import { formatMoney } from "../lib/format-money.mjs";

const now = Date.parse("2026-11-15T06:00:00Z");

test("holdMinutesLeft floors and never goes below 0", () => {
  assert.equal(holdMinutesLeft("2026-11-15T06:14:30Z", now), 14); // 14m30s -> 14
  assert.equal(holdMinutesLeft("2026-11-15T06:15:00Z", now), 15);
  assert.equal(holdMinutesLeft("2026-11-15T06:00:30Z", now), 0);  // 30s left
  assert.equal(holdMinutesLeft("2026-11-15T05:59:00Z", now), 0);  // already past
  assert.equal(holdMinutesLeft(null, now), 0);
  assert.equal(holdMinutesLeft("not-a-date", now), 0);
});

test("holdLabel reads 'Payment pending' with the minutes left", () => {
  assert.equal(holdLabel(14), "Payment pending · 14 min left");
  assert.equal(holdLabel(1), "Payment pending · 1 min left");
  assert.equal(holdLabel(0), "Payment pending · less than a minute left");
  assert.equal(holdLabel(-3), "Payment pending · less than a minute left");
});

test("the re-tap refusal is the hold wording", () => {
  assert.equal(RESERVATION_HOLD_RETAP, "Finish paying for this class first, or cancel the hold.");
  assert.ok(!RESERVATION_HOLD_RETAP.includes("—")); // no em dash
});

test("formatMoney drops .00 for a whole amount, keeps it for a fraction", () => {
  assert.equal(formatMoney(50000, "PHP"), "₱500");       // 500 -> ₱500
  assert.equal(formatMoney(105000, "PHP"), "₱1,050");    // 1050 -> ₱1,050
  assert.equal(formatMoney(49950, "PHP"), "₱499.50");    // 499.5 -> ₱499.50
  assert.equal(formatMoney(0, "PHP"), "₱0");
});

// Decision 26(e): the roster hold countdown.
test("holdCountdownText counts mm:ss down and names the expired state", () => {
  const t0 = Date.parse("2026-11-15T06:00:00Z");
  assert.equal(holdCountdownText("2026-11-15T06:14:05Z", t0), "Payment pending, 14:05 left");
  assert.equal(holdCountdownText("2026-11-15T06:00:09Z", t0), "Payment pending, 0:09 left");
  assert.equal(holdCountdownText("2026-11-15T06:00:00Z", t0), "Hold ended, fee not received, releasing");
  assert.equal(holdCountdownText("2026-11-15T05:59:00Z", t0), "Hold ended, fee not received, releasing");
  assert.equal(holdCountdownText(null, t0), "Payment pending");
  assert.equal(holdCountdownText("not-a-date", t0), "Payment pending");
});
