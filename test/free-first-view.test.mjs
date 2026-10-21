import { test } from "node:test";
import assert from "node:assert/strict";
import { freeEligibleSet, whichView, nearestEligibleDay, trialsMarker } from "../lib/free-first-view.mjs";

test("freeEligibleSet keeps only free_bookable rows", () => {
  const s = freeEligibleSet([
    { occurrence_id: "a", free_bookable: true },
    { occurrence_id: "b", free_bookable: false },  // full for free — not Book-free
    { occurrence_id: "c", free_bookable: true },
  ]);
  assert.deepEqual([...s].sort(), ["a", "c"]);
  assert.equal(s.has("b"), false);
  assert.equal(freeEligibleSet().size, 0);
});

test("whichView: picker only when eligible + has classes + not ?all", () => {
  assert.equal(whichView({ freeFirstEligible: true, eligibleCount: 3, showAll: false }), "picker");
  assert.equal(whichView({ freeFirstEligible: true, eligibleCount: 3, showAll: true }), "timetable");
  assert.equal(whichView({ freeFirstEligible: true, eligibleCount: 0, showAll: false }), "timetable");
  assert.equal(whichView({ freeFirstEligible: false, eligibleCount: 3, showAll: false }), "timetable");
});

test("nearestEligibleDay: that day, else nearest, first when no want", () => {
  const keys = ["2026-10-20", "2026-10-22", "2026-10-26"];
  assert.equal(nearestEligibleDay(keys, "2026-10-22"), "2026-10-22");   // exact
  assert.equal(nearestEligibleDay(keys, "2026-10-21"), "2026-10-20");   // nearest (tie -> earlier)
  assert.equal(nearestEligibleDay(keys, "2026-10-25"), "2026-10-26");   // nearest
  assert.equal(nearestEligibleDay(keys, null), "2026-10-20");           // no want -> first
  assert.equal(nearestEligibleDay(keys, "garbage"), "2026-10-20");      // bad -> first
  assert.equal(nearestEligibleDay([], "2026-10-22"), null);             // none
});

// Decision 30 amendment (b) follow-up — the calendar-block trials marker: EXCEPTIONS
// in both directions, and only exceptions.
test("trialsMarker: Trials when an override opens a rules-closed class", () => {
  assert.equal(trialsMarker({ override: "open", rulesOpen: false }), "trials");
});
test("trialsMarker: No trials when an override closes a rules-open class", () => {
  assert.equal(trialsMarker({ override: "closed", rulesOpen: true }), "no_trials");
});
test("trialsMarker: nothing when the override merely repeats the rules, or none", () => {
  assert.equal(trialsMarker({ override: "open", rulesOpen: true }), null);    // repeats open
  assert.equal(trialsMarker({ override: "closed", rulesOpen: false }), null); // repeats closed
  assert.equal(trialsMarker({ override: null, rulesOpen: true }), null);      // follow rules (open)
  assert.equal(trialsMarker({ override: null, rulesOpen: false }), null);     // follow rules (closed)
  assert.equal(trialsMarker(null), null);
  assert.equal(trialsMarker(undefined), null);
});
