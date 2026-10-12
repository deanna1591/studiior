// Decision 76b — the pure group-booking helpers. Zero deps:
//   node --test test/group.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { validateGroupEmails, eligibleGroupClasses } from "../lib/group.mjs";

const HOST = "hugo@example.com";

test("validateGroupEmails: a clean set of distinct non-host emails passes", () => {
  assert.deepEqual(validateGroupEmails(["a@x.com", "b@x.com"], HOST, 3), { ok: true });
});

test("validateGroupEmails: wrong count is caught (group of 3 needs 2 emails)", () => {
  const r = validateGroupEmails(["a@x.com"], HOST, 3);
  assert.equal(r.ok, false);
  assert.equal(r.reason, "wrong_count");
  assert.equal(r.expected, 2);
});

test("validateGroupEmails: a blank email is caught with its index", () => {
  const r = validateGroupEmails(["a@x.com", "  "], HOST, 3);
  assert.equal(r.reason, "blank");
  assert.equal(r.index, 1);
});

test("validateGroupEmails: the host's own email is refused (case/space-insensitive)", () => {
  const r = validateGroupEmails(["a@x.com", " HUGO@example.com "], HOST, 3);
  assert.equal(r.reason, "is_host");
  assert.equal(r.index, 1);
});

test("validateGroupEmails: a duplicate guest is refused (case-insensitive)", () => {
  const r = validateGroupEmails(["a@x.com", "A@X.com"], HOST, 3);
  assert.equal(r.reason, "duplicate");
  assert.equal(r.index, 1);
});

test("eligibleGroupClasses: keeps future classes with room for the whole group, soonest first", () => {
  const now = Date.parse("2026-11-01T00:00:00Z");
  const classes = [
    { id: "past", starts_at: "2026-10-30T10:00:00Z", capacity: 10, booked_count: 0 },      // past
    { id: "tight", starts_at: "2026-11-03T10:00:00Z", capacity: 10, booked_count: 8 },      // 2 free < 3
    { id: "ok2", starts_at: "2026-11-05T10:00:00Z", capacity: 10, booked_count: 7 },        // 3 free
    { id: "ok1", starts_at: "2026-11-02T10:00:00Z", capacity: 6, booked_count: 0 },         // 6 free
    { id: "cancelled", starts_at: "2026-11-04T10:00:00Z", status: "cancelled", capacity: 10, booked_count: 0 },
  ];
  const got = eligibleGroupClasses(classes, 3, now).map((c) => c.id);
  assert.deepEqual(got, ["ok1", "ok2"]);
});

test("eligibleGroupClasses: held seats count against free", () => {
  const now = Date.parse("2026-11-01T00:00:00Z");
  const classes = [
    { id: "held", starts_at: "2026-11-02T10:00:00Z", capacity: 5, booked_count: 1, seats_held: 2 }, // 2 free < 3
    { id: "free", starts_at: "2026-11-02T10:00:00Z", capacity: 5, booked_count: 1, seats_held: 1 }, // 3 free
  ];
  assert.deepEqual(eligibleGroupClasses(classes, 3, now).map((c) => c.id), ["free"]);
});
