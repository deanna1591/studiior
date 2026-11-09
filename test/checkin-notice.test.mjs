import { test } from "node:test";
import assert from "node:assert/strict";
import { checkinNotice } from "../lib/checkin-notice.mjs";

// Stub studio clock: HH:MM in UTC, so the assertions are timezone-stable.
const fmt = (ms) => new Date(ms).toISOString().slice(11, 16);
const START = Date.UTC(2026, 10, 10, 8, 0); // 08:00
const booking = (over = {}) => ({ name: "Reformer Flow", startsAt: START, endsAt: START + 50 * 60000, ...over });

test("not-open: booked today, window has not opened yet", () => {
  const r = checkinNotice({ booking: booking(), now: START - 60 * 60000, opensBefore: 15, closesAfter: 15, waiverOk: true, fmt });
  assert.equal(r.kind, "not_open");
  assert.equal(r.text, "You're booked for Reformer Flow at 08:00. You can check in 15 minutes before class.");
});

test("not-open: the minutes come from opensBefore, never typed", () => {
  const r = checkinNotice({ booking: booking(), now: START - 60 * 60000, opensBefore: 30, closesAfter: 15, waiverOk: true, fmt });
  assert.match(r.text, /check in 30 minutes before class\.$/);
});

test("closed: window has passed", () => {
  const closesAt = START + 50 * 60000 + 15 * 60000; // ends + closesAfter
  const r = checkinNotice({ booking: booking(), now: closesAt + 60000, opensBefore: 15, closesAfter: 15, waiverOk: true, fmt });
  assert.equal(r.kind, "closed");
  assert.equal(r.text, `Check-in for Reformer Flow closed at ${fmt(closesAt)}. Check in with your instructor.`);
});

test("closed: with no end time, closes relative to the start", () => {
  const closesAt = START + 15 * 60000;
  const r = checkinNotice({ booking: booking({ endsAt: null }), now: closesAt + 60000, opensBefore: 15, closesAfter: 15, waiverOk: true, fmt });
  assert.equal(r.kind, "closed");
  assert.equal(r.text, `Check-in for Reformer Flow closed at ${fmt(closesAt)}. Check in with your instructor.`);
});

test("none-today: no booking", () => {
  const r = checkinNotice({ booking: null, now: START, opensBefore: 15, closesAfter: 15, waiverOk: true, fmt });
  assert.equal(r.kind, "none");
  assert.equal(r.text, "No class to check in to right now.");
});

test("waiver-missing: in the window, waiver unsigned", () => {
  const r = checkinNotice({ booking: booking(), now: START, opensBefore: 15, closesAfter: 15, waiverOk: false, fmt });
  assert.equal(r.kind, "waiver");
  assert.equal(r.text, "Please sign the waiver first before checking in.");
});

test("open: in the window, waiver fine, so no notice", () => {
  const r = checkinNotice({ booking: booking(), now: START, opensBefore: 15, closesAfter: 15, waiverOk: true, fmt });
  assert.equal(r.kind, "open");
  assert.equal(r.text, null);
});

test("no em dash in any sentence", () => {
  for (const waiverOk of [true, false]) {
    for (const now of [START - 3600000, START, START + 7200000]) {
      const r = checkinNotice({ booking: booking(), now, opensBefore: 15, closesAfter: 15, waiverOk, fmt });
      if (r.text) assert.ok(!r.text.includes("—"), `em dash in: ${r.text}`);
    }
  }
});
