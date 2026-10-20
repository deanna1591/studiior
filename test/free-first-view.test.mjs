import { test } from "node:test";
import assert from "node:assert/strict";
import { freeEligibleSet, whichView, nearestEligibleDay, showsTrialsMarker } from "../lib/free-first-view.mjs";

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

// Decision 30 amendment (b) follow-up — the "Trials" calendar-block marker.
test("showsTrialsMarker: only an effectively-open OVERRIDE shows it", () => {
  assert.equal(showsTrialsMarker({ override: "open", effectiveOpen: true }), true);
  // A rules-open class (no override) gets no marker — it would be on every core class.
  assert.equal(showsTrialsMarker({ override: null, effectiveOpen: true }), false);
  // Closed, either way, never.
  assert.equal(showsTrialsMarker({ override: "closed", effectiveOpen: false }), false);
  // override 'open' but not effectively open (studio switch off) — no marker.
  assert.equal(showsTrialsMarker({ override: "open", effectiveOpen: false }), false);
  // Null / missing state (studio doesn't use free first classes).
  assert.equal(showsTrialsMarker(null), false);
  assert.equal(showsTrialsMarker(undefined), false);
});
