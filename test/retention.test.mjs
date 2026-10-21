import { test } from "node:test";
import assert from "node:assert/strict";
import {
  freeStageWord, methodWord, outcomeClause, outcomeLine, stateLine, snoozeLabel, SNOOZE_DAYS,
} from "../lib/retention.mjs";

test("freeStageWord maps the three stages", () => {
  assert.equal(freeStageWord("taken"), "taken");
  assert.equal(freeStageWord("missed"), "missed");
  assert.equal(freeStageWord("booked"), "booked");
  assert.equal(freeStageWord(null), "booked");
});

test("methodWord reads as a past-tense verb", () => {
  assert.equal(methodWord("email"), "Emailed");
  assert.equal(methodWord("viber"), "Messaged on Viber");
  assert.equal(methodWord("call"), "Called");
  assert.equal(methodWord("in_person"), "Spoke in person");
});

test("outcomeClause: each outcome, singular/plural days, none, null", () => {
  assert.equal(outcomeClause("booked", 2), "Booked 2 days later");
  assert.equal(outcomeClause("visited", 1), "Came back 1 day later");
  assert.equal(outcomeClause("bought", 5), "Bought a plan 5 days later");
  assert.equal(outcomeClause("renewed", 0), "Renewed 0 days later");
  assert.equal(outcomeClause("none"), "No change after 14 days");
  assert.equal(outcomeClause(null), null);
});

test("outcomeLine: head + outcome tail, days-ago maths", () => {
  const now = new Date("2026-10-21T12:00:00Z").getTime();
  assert.equal(
    outcomeLine({ method: "email", contactedAt: "2026-10-18T12:00:00Z", outcome: "booked", outcomeDays: 2, now }),
    "Emailed 3 days ago · Booked 2 days later");
  assert.equal(
    outcomeLine({ method: "email", contactedAt: "2026-10-07T12:00:00Z", outcome: "none", outcomeDays: 14, now }),
    "Emailed 14 days ago · No change after 14 days");
  assert.equal(
    outcomeLine({ method: "viber", contactedAt: "2026-10-21T06:00:00Z", outcome: null, now }),
    "Messaged on Viber today");
  assert.equal(outcomeLine({ method: "email", contactedAt: null, now }), null);
});

test("stateLine: free cohort, health band, expiring, none", () => {
  assert.equal(
    stateLine({ plan_state: "free_only", free_stage: "taken", days_since: 9 }),
    "Free class taken 9 days ago · no plan yet");
  assert.equal(
    stateLine({ plan_state: "on_plan", health_band: "at_risk",
                health_reason: "Was coming about every 4 days, last visit 16 days ago." }),
    "Was coming about every 4 days, last visit 16 days ago.");
  assert.equal(
    stateLine({ plan_state: "expiring", current_plan_name: "Unlimited Monthly", expires_on: "Fri 24 Oct" }),
    "Unlimited Monthly ends Fri 24 Oct");
  assert.equal(stateLine({ plan_state: "none" }), "Signed up, nothing booked");
  assert.equal(stateLine(null), "");
});

test("snooze offsets and label", () => {
  assert.deepEqual(SNOOZE_DAYS, [3, 7, 14]);
  assert.equal(snoozeLabel(1), "Remind me in 1 day");
  assert.equal(snoozeLabel(7), "Remind me in 7 days");
});
