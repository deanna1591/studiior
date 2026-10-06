import { test } from "node:test";
import assert from "node:assert/strict";
import { classButtonState } from "../lib/class-button.mjs";

// A class at a fixed instant; opens 10 before, closes 30 after (Reform's values).
const START = Date.UTC(2026, 9, 10, 7, 0, 0);
const END = START + 50 * 60000;
const base = { startsMs: START, endsMs: END, opensBeforeMin: 10, closesAfterMin: 30 };
const at = (min) => START + min * 60000; // minutes relative to start

test("unbooked is Book", () => {
  assert.equal(classButtonState({ ...base, bookingStatus: null, nowMs: at(-60) }), "book");
});

test("booked before the window is Reserved", () => {
  // 11 min before start, window opens at 10 min before -> not open yet.
  assert.equal(classButtonState({ ...base, bookingStatus: "booked", nowMs: at(-11) }), "reserved");
});

test("booked inside the window (just opened) is Check in", () => {
  assert.equal(classButtonState({ ...base, bookingStatus: "booked", nowMs: at(-10) }), "checkin");
  assert.equal(classButtonState({ ...base, bookingStatus: "booked", nowMs: at(0) }), "checkin");
});

test("after the class starts, still inside the window, is Check in", () => {
  // closes 30 after -> 20 min past start is still open.
  assert.equal(classButtonState({ ...base, bookingStatus: "booked", nowMs: at(20) }), "checkin");
});

test("after the window closes is Reserved again", () => {
  // 31 min past start (ends +50, closes at end+30 = +80) ... end is +50, closes at +80.
  assert.equal(classButtonState({ ...base, bookingStatus: "booked", nowMs: at(81) }), "reserved");
});

test("checked in is Checked in, even inside the window", () => {
  assert.equal(classButtonState({ ...base, bookingStatus: "booked", checkedIn: true, nowMs: at(-5) }), "checked_in");
});

test("an attended booking is Checked in (self_check_in flipped the status)", () => {
  assert.equal(classButtonState({ ...base, bookingStatus: "attended", nowMs: at(5) }), "checked_in");
});

test("a flex class awaiting confirmation is Waiting for confirmation", () => {
  // Even inside the window, pending wins until confirmed.
  assert.equal(classButtonState({ ...base, bookingStatus: "booked", flexPending: true, nowMs: at(-5) }), "waiting_confirmation");
  assert.equal(classButtonState({ ...base, bookingStatus: "booked", flexPending: true, nowMs: at(-60) }), "waiting_confirmation");
});

test("once a flex class is confirmed it follows the window (reserved -> checkin)", () => {
  assert.equal(classButtonState({ ...base, bookingStatus: "booked", flexPending: false, nowMs: at(-60) }), "reserved");
  assert.equal(classButtonState({ ...base, bookingStatus: "booked", flexPending: false, nowMs: at(-5) }), "checkin");
});

test("waitlisted stays Waitlisted", () => {
  assert.equal(classButtonState({ ...base, bookingStatus: "waitlisted", nowMs: at(-5) }), "waitlisted");
});

test("a cancelled class is Cancelled, whatever the booking", () => {
  assert.equal(classButtonState({ ...base, bookingStatus: "booked", cancelled: true, nowMs: at(-5) }), "cancelled");
  assert.equal(classButtonState({ ...base, bookingStatus: "attended", cancelled: true, nowMs: at(5) }), "cancelled");
});

// Decision 68 amendment — the Book-list row maps as the page builds it: a
// booked row before the window is Reserved; a checked-in row (status attended,
// OR the day's check_ins set) is Checked in — the regression the Book-list SQL
// suite proves the data for.
test("Book-list row: booked before window -> Reserved", () => {
  assert.equal(classButtonState({ ...base, bookingStatus: "booked", checkedIn: false, nowMs: at(-120) }), "reserved");
});
test("Book-list row: checked in (status attended) -> Checked in", () => {
  assert.equal(classButtonState({ ...base, bookingStatus: "attended", checkedIn: true, nowMs: at(5) }), "checked_in");
});
test("Book-list row: booked + check-in seen by the set -> Checked in", () => {
  // status stays 'booked' for a scan (method instructor); checkedIn flag drives it.
  assert.equal(classButtonState({ ...base, bookingStatus: "booked", checkedIn: true, nowMs: at(5) }), "checked_in");
});

test("no end time falls back to the start for the close boundary", () => {
  // closes 30 after START; 31 min past start -> reserved.
  assert.equal(classButtonState({ startsMs: START, endsMs: null, opensBeforeMin: 10, closesAfterMin: 30,
    bookingStatus: "booked", nowMs: at(31) }), "reserved");
  assert.equal(classButtonState({ startsMs: START, endsMs: null, opensBeforeMin: 10, closesAfterMin: 30,
    bookingStatus: "booked", nowMs: at(29) }), "checkin");
});
