// node --test test/cancel-notice.test.mjs
// Decision 36 amendment — the cancel rule shown before the tap, and the result
// after. Every seat kind, before / after / started, plus the result sentences.

import { test } from "node:test";
import assert from "node:assert/strict";
import { seatKindOf, cancelNotice, cancelResult } from "../lib/cancel-notice.mjs";

// Fixed studio-clock formatters so the assertions are deterministic.
const fmtTime = () => "8:00 PM";
const fmtDay = () => "Saturday 8 November";

const CUT = 720;                 // 12 h, Reform
const START = 2_000_000_000_000; // some future ms
const before = START - 20 * 3_600_000; // 20 h before: before the cutoff
const after = START - 3 * 3_600_000;   // 3 h before: inside the cutoff
const started = START + 60_000;        // past start

test("seatKindOf — every bucket", () => {
  assert.equal(seatKindOf({ isFreeBooking: true, paymentSource: "comp" }), "free");
  assert.equal(seatKindOf({ paymentSource: "drop_in" }), "drop_in");
  assert.equal(seatKindOf({ paymentSource: "membership", creditEntryId: "c1" }), "credit");
  assert.equal(seatKindOf({ paymentSource: "class_pack", creditEntryId: null }), "credit");
  assert.equal(seatKindOf({ paymentSource: "membership", creditEntryId: null }), "unlimited");
  assert.equal(seatKindOf({ paymentSource: "comp", isFreeBooking: false }), "unlimited");
  assert.equal(seatKindOf({}), "unlimited");
});

test("cancelNotice — before the cutoff, per seat kind", () => {
  const n = (seatKind) => cancelNotice({ startsMs: START, cutoffMinutes: CUT, nowMs: before, seatKind, fmtTime, fmtDay });
  assert.deepEqual(n("free"), { phase: "before", line: "Free to cancel until 8:00 PM on Saturday 8 November. After that your free class is used." });
  assert.deepEqual(n("credit"), { phase: "before", line: "Free to cancel until 8:00 PM on Saturday 8 November. After that your credit is used." });
  assert.deepEqual(n("unlimited"), { phase: "before", line: "Free to cancel until 8:00 PM on Saturday 8 November. After that it counts as a late cancel." });
  assert.deepEqual(n("drop_in"), { phase: "before", line: "Free to cancel until 8:00 PM on Saturday 8 November." });
});

test("cancelNotice — after the cutoff, per seat kind", () => {
  const n = (seatKind) => cancelNotice({ startsMs: START, cutoffMinutes: CUT, nowMs: after, seatKind, fmtTime, fmtDay });
  assert.deepEqual(n("free"), { phase: "after", line: "It's less than 12 hours before class. Cancelling now uses your free class." });
  assert.deepEqual(n("credit"), { phase: "after", line: "It's less than 12 hours before class. Cancelling now uses your credit." });
  assert.deepEqual(n("unlimited"), { phase: "after", line: "It's less than 12 hours before class. Cancelling now counts as a late cancel." });
  assert.deepEqual(n("drop_in"), { phase: "after", line: "It's less than 12 hours before class." });
});

test("cancelNotice — started: no button, one line", () => {
  const r = cancelNotice({ startsMs: START, cutoffMinutes: CUT, nowMs: started, seatKind: "free", fmtTime, fmtDay });
  assert.deepEqual(r, { phase: "started", line: "This class has started." });
});

test("cancelNotice — a sub-hour cutoff reads 'hour', not 'hours'", () => {
  const r = cancelNotice({ startsMs: START, cutoffMinutes: 45, nowMs: START - 60_000, seatKind: "drop_in", fmtTime, fmtDay });
  assert.equal(r.line, "It's less than 1 hour before class.");
});

test("cancelResult — free class, credit, and everything else", () => {
  assert.equal(cancelResult({ seatKind: "free", late: true, creditReturned: false }), "Cancelled. Your free class was used.");
  assert.equal(cancelResult({ seatKind: "free", late: false, creditReturned: false }), "Cancelled. Your free class is still yours.");
  assert.equal(cancelResult({ seatKind: "credit", late: true, creditReturned: false }), "Cancelled. Your credit was used.");
  assert.equal(cancelResult({ seatKind: "credit", late: false, creditReturned: true }), "Cancelled. Your credit is back on your account.");
  // A late cancel at a studio that does NOT consume the credit returns it.
  assert.equal(cancelResult({ seatKind: "credit", late: true, creditReturned: true }), "Cancelled. Your credit is back on your account.");
  assert.equal(cancelResult({ seatKind: "unlimited", late: true, creditReturned: false }), "Cancelled.");
  assert.equal(cancelResult({ seatKind: "drop_in", late: true, creditReturned: false }), "Cancelled.");
});

test("no em dashes in any produced sentence", () => {
  const lines = [];
  for (const phase of [before, after, started]) {
    for (const seatKind of ["free", "credit", "unlimited", "drop_in"]) {
      lines.push(cancelNotice({ startsMs: START, cutoffMinutes: CUT, nowMs: phase, seatKind, fmtTime, fmtDay }).line);
    }
  }
  for (const seatKind of ["free", "credit", "unlimited", "drop_in"]) {
    for (const late of [true, false]) {
      for (const creditReturned of [true, false]) {
        lines.push(cancelResult({ seatKind, late, creditReturned }));
      }
    }
  }
  for (const l of lines) assert.ok(!l.includes("—"), `em dash in: ${l}`);
});
