import { test } from "node:test";
import assert from "node:assert/strict";
import {
  clampFrac, occScore, weightFor, slotScore, hasEnoughHistory,
  collectingLabel, qualifies, RECENT_WEEKS,
} from "../lib/growth-score.mjs";

const near = (a, b, eps = 1e-9) => assert.ok(Math.abs(a - b) < eps, `${a} !~= ${b}`);

test("clampFrac: fraction, clamped at 1, zero capacity is 0", () => {
  near(clampFrac(4, 8), 0.5);
  near(clampFrac(8, 8), 1);
  // Comps/guests/walk-ins can exceed capacity — still 1.0, never above.
  near(clampFrac(10, 8), 1);
  near(clampFrac(3, 0), 0);
  near(clampFrac(0, 8), 0);
});

test("occScore: a full, well-attended, no-waste class scores high", () => {
  // full (8/8=1), all attended (1), no waitlist, no waste → 0.6 + 0.25 = 0.85
  near(occScore({ booked: 8, capacity: 8, attended: 8, waitlist: 0, noShow: 0, lateCancel: 0 }), 0.85);
});

test("occScore: an over-capacity class is clamped, not inflated", () => {
  // 10 booked in an 8 room: bookedFrac clamps to 1, attendedFrac 8/10=0.8
  // 0.6*1 + 0.25*0.8 + 0.15*min(0/8,0.5) - 0.2*0 = 0.6 + 0.2 = 0.8
  near(occScore({ booked: 10, capacity: 8, attended: 8, waitlist: 0, noShow: 0, lateCancel: 0 }), 0.8);
});

test("occScore: no-shows and late cancels pull it down; a waitlist lifts it a little", () => {
  // 6/8 booked (0.75), 4 attended of 6 (0.666..), waitlist 2 (2/8=0.25), 2 no-shows (2/8=0.25)
  const s = occScore({ booked: 6, capacity: 8, attended: 4, waitlist: 2, noShow: 2, lateCancel: 0 });
  near(s, 0.6 * 0.75 + 0.25 * (4 / 6) + 0.15 * 0.25 - 0.2 * 0.25);
  // the waitlist bonus is capped at 0.5 of the fraction
  const capped = occScore({ booked: 8, capacity: 8, attended: 8, waitlist: 100, noShow: 0, lateCancel: 0 });
  near(capped, 0.6 + 0.25 + 0.15 * 0.5);
});

test("weightFor: the last four weeks count double", () => {
  assert.equal(weightFor(0), 2);
  assert.equal(weightFor(3), 2);
  assert.equal(weightFor(4), 1);
  assert.equal(weightFor(7), 1);
});

test("slotScore: weighted to the last four weeks", () => {
  const good = { booked: 8, capacity: 8, attended: 8, waitlist: 0, noShow: 0, lateCancel: 0 }; // 0.85
  const bad = { booked: 1, capacity: 8, attended: 1, waitlist: 0, noShow: 0, lateCancel: 0 };
  // newest four good, oldest four bad → weighted toward good
  const weeks = [good, good, good, good, bad, bad, bad, bad];
  const sb = occScore(bad);
  const expect = (2 * 0.85 * 4 + 1 * sb * 4) / (2 * 4 + 1 * 4);
  near(slotScore(weeks), expect);
  assert.equal(slotScore([]), 0);
});

test("hasEnoughHistory + collectingLabel", () => {
  assert.equal(hasEnoughHistory(0), false);
  assert.equal(hasEnoughHistory(3), false);
  assert.equal(hasEnoughHistory(4), true);
  assert.equal(hasEnoughHistory(8), true);
  assert.equal(collectingLabel(2), "Collecting data, 2 of 4 weeks");
  assert.equal(collectingLabel(0), "Collecting data, 0 of 4 weeks");
  assert.equal(RECENT_WEEKS, 4);
});

test("qualifies: reached the flex minimum in three of the last four weeks", () => {
  const w = (booked) => ({ booked, capacity: 8, attended: booked, waitlist: 0, noShow: 0, lateCancel: 0 });
  // flexMin 2; last four = newest four
  assert.equal(qualifies([w(3), w(3), w(3), w(1), w(5)], 2), true); // 3 of first 4 met
  assert.equal(qualifies([w(3), w(1), w(1), w(3), w(5)], 2), false); // only 2 of first 4 met
  // fewer than four weeks → never qualifies (collecting data)
  assert.equal(qualifies([w(8), w(8), w(8)], 2), false);
  // exactly three met in the last four
  assert.equal(qualifies([w(2), w(2), w(2), w(0)], 2), true);
});

// --- Decision 106 (a) -------------------------------------------------------
import { metStreak, emptyStreak, suggestionLine, weekBudget } from "../lib/growth-score.mjs";

test("streaks count from the most recent week", () => {
  const wk = (b) => ({ booked: b });
  assert.equal(metStreak([wk(3), wk(2), wk(1), wk(4)], 2), 2);
  assert.equal(metStreak([wk(1), wk(5)], 2), 0);
  assert.equal(emptyStreak([wk(0), wk(0), wk(3)]), 2);
  assert.equal(emptyStreak([wk(1), wk(0)]), 0);
});

test("the suggestion lines read plainly", () => {
  assert.equal(suggestionLine({ action: "make_core", metStreak: 3, emptyStreak: 0, met4: 3, lastBooked: 4, flexMin: 2 }),
    "Reached 2 of 2 three weeks running. Make it core?");
  assert.equal(suggestionLine({ action: "make_flex", metStreak: 0, emptyStreak: 4, met4: 0, lastBooked: 0, flexMin: 2 }),
    "Empty four weeks running. Make it flex?");
  assert.equal(suggestionLine({ action: "make_flex", metStreak: 0, emptyStreak: 1, met4: 2, lastBooked: 0, flexMin: 2 }),
    "Reached the minimum in two of the last four weeks. Make it flex?");
  assert.equal(suggestionLine({ action: null, metStreak: 0, emptyStreak: 0, met4: 0, lastBooked: 0, flexMin: 2 }), null);
});

test("the weekly budget flags, it never drops a proposal", () => {
  const out = weekBudget(3, 3, [
    { id: "a", score: 0.5, classes: 1 },
    { id: "b", score: 0.9, classes: 1 },
  ]);
  assert.deepEqual(out, [
    { id: "b", wouldHold: 4, overBudget: true },
    { id: "a", wouldHold: 5, overBudget: true },
  ]);
  // three on one day under a weekly cap of 3: none over.
  assert.ok(weekBudget(0, 3, [1, 2, 3].map((i) => ({ id: String(i), score: i, classes: 1 }))).every((x) => !x.overBudget));
});
