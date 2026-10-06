import { test } from "node:test";
import assert from "node:assert/strict";
import { classSheetView } from "../lib/class-sheet.mjs";

const START = Date.UTC(2026, 9, 10, 7, 0, 0);
const END = START + 50 * 60000;
const base = { startsMs: START, endsMs: END, opensBeforeMin: 10, closesAfterMin: 30 };
const at = (min) => START + min * 60000;

test("attended -> checked_in, no actions, capacity hidden", () => {
  const v = classSheetView({ ...base, bookingStatus: "attended", checkedIn: true, nowMs: at(5) });
  assert.equal(v.state, "checked_in");
  assert.deepEqual(v.actions, []);
  assert.equal(v.hideCapacity, true);
});

test("booked inside the window -> checkin (+ cancel), capacity hidden", () => {
  const v = classSheetView({ ...base, bookingStatus: "booked", nowMs: at(-5) });
  assert.equal(v.state, "checkin");
  assert.ok(v.actions.includes("checkin"));
  assert.ok(v.actions.includes("cancel"));
  assert.equal(v.hideCapacity, true);
});

test("booked outside the window -> reserved + cancel", () => {
  const v = classSheetView({ ...base, bookingStatus: "booked", nowMs: at(-120) });
  assert.equal(v.state, "reserved");
  assert.deepEqual(v.actions, ["cancel"]);
  assert.equal(v.hideCapacity, true);
});

test("waitlisted -> leave", () => {
  const v = classSheetView({ ...base, bookingStatus: "waitlisted", nowMs: at(-120) });
  assert.equal(v.state, "waitlisted");
  assert.deepEqual(v.actions, ["leave"]);
  assert.equal(v.hideCapacity, true);
});

test("no booking + full -> waitlist (when enabled), capacity shown", () => {
  const v = classSheetView({ ...base, bookingStatus: null, full: true, waitlistEnabled: true, nowMs: at(-120) });
  assert.equal(v.state, "book");
  assert.deepEqual(v.actions, ["waitlist"]);
  assert.equal(v.hideCapacity, false);
});

test("no booking + full + no waitlist -> no actions, capacity shown", () => {
  const v = classSheetView({ ...base, bookingStatus: null, full: true, waitlistEnabled: false, nowMs: at(-120) });
  assert.deepEqual(v.actions, []);
  assert.equal(v.hideCapacity, false);
});

test("no booking + seats -> book, capacity shown", () => {
  const v = classSheetView({ ...base, bookingStatus: null, full: false, nowMs: at(-120) });
  assert.equal(v.state, "book");
  assert.deepEqual(v.actions, ["book"]);
  assert.equal(v.hideCapacity, false);
});

test("free-first eligible + seats -> bookfree", () => {
  const v = classSheetView({ ...base, bookingStatus: null, full: false, freeFirstEligible: true, nowMs: at(-120) });
  assert.deepEqual(v.actions, ["bookfree"]);
});

test("flex pending booked -> waiting_confirmation + cancel", () => {
  const v = classSheetView({ ...base, bookingStatus: "booked", flexPending: true, nowMs: at(-5) });
  assert.equal(v.state, "waiting_confirmation");
  assert.deepEqual(v.actions, ["cancel"]);
  assert.equal(v.hideCapacity, true);
});
