// Decision 58 fix — notificationHref mapping.
//   node --test test/notification-href.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";
import { notificationHref } from "../lib/notification-href.mjs";

const OCC = "11111111-1111-1111-1111-111111111111";

test("cover request / urgent / open shifts → /instructor/shifts", () => {
  for (const k of ["cover_available", "cover_urgent", "cover_asked", "open_shifts_available",
    "shift_approved", "shift_declined", "shift_withdrawn"]) {
    assert.equal(notificationHref(k, { occurrence_id: OCC }), "/instructor/shifts", k);
  }
});

test("cover outcome → roster when occurrence_id present, else schedule", () => {
  for (const k of ["cover_approved", "cover_declined", "cover_auto_covered",
    "cover_asked_confirmed", "cover_asked_declined", "cover_colleague_declined"]) {
    assert.equal(notificationHref(k, { occurrence_id: OCC }), `/instructor/roster/${OCC}`, `${k} with occ`);
    assert.equal(notificationHref(k, {}), "/instructor/schedule", `${k} without occ`);
  }
});

test("monthly roster → /instructor/month?m= from month_ym or period_start", () => {
  assert.equal(notificationHref("month_roster", { month_ym: "2026-11" }), "/instructor/month?m=2026-11");
  assert.equal(notificationHref("month_roster_plain", { period_start: "2026-11-01" }), "/instructor/month?m=2026-11");
  assert.equal(notificationHref("month_roster", {}), null); // no month key → null, not a guess
});

test("single-class notices → roster/{occurrence_id}", () => {
  for (const k of ["instructor_assigned", "instructor_class_cancelled", "instructor_substituted",
    "class_reassigned_off", "instructor_booking_alert", "booking_for_instructor", "shift_taken_off"]) {
    assert.equal(notificationHref(k, { occurrence_id: OCC }), `/instructor/roster/${OCC}`, k);
  }
});

test("class-reminder digests have no occurrence_id → null (fallback, not a guess)", () => {
  assert.equal(notificationHref("instructor_week_ahead", { class_list: "…", schedule_link: "x" }), null);
  assert.equal(notificationHref("instructor_tomorrow", { class_list: "…" }), null);
  // and a single-class notice missing its id is also null
  assert.equal(notificationHref("instructor_assigned", {}), null);
});

test("availability → /instructor/availability", () => {
  for (const k of ["availability_due", "availability_changes_requested",
    "availability_approved", "availability_narrowed_instructor"]) {
    assert.equal(notificationHref(k, {}), "/instructor/availability", k);
  }
});

test("pay / period closed → /instructor/pay", () => {
  assert.equal(notificationHref("period_closed", {}), "/instructor/pay");
  assert.equal(notificationHref("pay_ready", {}), "/instructor/pay");
});

test("unknown kind → null", () => {
  assert.equal(notificationHref("flex_going_ahead", { occurrence_id: OCC }), null);
  assert.equal(notificationHref("week_confirm_ask", {}), null);
  assert.equal(notificationHref("something_new", { occurrence_id: OCC }), null);
  assert.equal(notificationHref("", null), null);
});
