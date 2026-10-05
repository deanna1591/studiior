// The "Availability" line shown on the Instructors list and detail — Decision 46
// follow-up. A standing weekly pattern (entered admin-side, no submission) is
// not "nothing yet". Runs with zero deps:
//   node --test test/availability_line.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { availabilityLine, standingNote, monthCoveredState } from "../lib/availability-line.mjs";

const base = { monthLabel: "November 2026", standing: null, instructorId: "abc" };

test("submitted → waiting for you, links to /availability", () => {
  const r = availabilityLine({ ...base, submissionStatus: "submitted" });
  assert.equal(r.text, "Availability: submitted · waiting for you");
  assert.equal(r.href, "/availability");
});

test("approved → names the month", () => {
  const r = availabilityLine({ ...base, submissionStatus: "approved" });
  assert.equal(r.text, "Availability: approved for November 2026");
  assert.equal(r.href, "/availability");
});

test("changes_requested → sent back", () => {
  const r = availabilityLine({ ...base, submissionStatus: "changes_requested" });
  assert.equal(r.text, "Availability: sent back");
});

test("no submission + standing pattern with an end → weekly pattern through {d Mon yyyy}", () => {
  const r = availabilityLine({
    ...base, submissionStatus: "none", standing: { endsOn: "2026-11-30" },
  });
  assert.equal(r.text, "Availability: weekly pattern through 30 Nov 2026");
  assert.equal(r.href, "/instructors/abc/availability");
  assert.equal(r.linkLabel, "View the week");
});

test("no submission + open-ended standing pattern → weekly pattern, no end date", () => {
  const r = availabilityLine({
    ...base, submissionStatus: "none", standing: { endsOn: null },
  });
  assert.equal(r.text, "Availability: weekly pattern, no end date");
  assert.equal(r.href, "/instructors/abc/availability");
});

test("neither → nothing yet", () => {
  assert.equal(
    availabilityLine({ ...base, submissionStatus: "none" }).text,
    "Availability: nothing yet");
  // null status behaves as none
  assert.equal(
    availabilityLine({ ...base, submissionStatus: null }).text,
    "Availability: nothing yet");
});

test("a submission wins over a standing pattern (precedence)", () => {
  const r = availabilityLine({
    ...base, submissionStatus: "approved", standing: { endsOn: "2026-11-30" },
  });
  assert.equal(r.text, "Availability: approved for November 2026");
});

test("standingNote: through a date, no end date, or empty", () => {
  assert.equal(standingNote({ endsOn: "2026-11-17" }), "weekly pattern through 17 Nov 2026");
  assert.equal(standingNote({ endsOn: null }), "weekly pattern, no end date");
  assert.equal(standingNote(null), "");
});

// monthCoveredState — the TS twin of SQL instructor_month_covered. These five
// cases mirror exactly what test/availability_on_file_test.sql asserts of the
// SQL function, so the two agree (Decision 46 amendment).
test("monthCoveredState: a submission wins (its status)", () => {
  assert.equal(monthCoveredState("submitted", false), "submitted");
  assert.equal(monthCoveredState("approved", true), "approved");
  assert.equal(monthCoveredState("changes_requested", true), "changes_requested");
});

test("monthCoveredState: no submission, a covering pattern → 'pattern'", () => {
  assert.equal(monthCoveredState(null, true), "pattern");
  assert.equal(monthCoveredState("none", true), "pattern");
  // a draft is treated as no submission (falls through to the pattern)
  assert.equal(monthCoveredState("draft", true), "pattern");
});

test("monthCoveredState: nothing on file → 'none'", () => {
  assert.equal(monthCoveredState(null, false), "none");
  assert.equal(monthCoveredState("draft", false), "none");
});
