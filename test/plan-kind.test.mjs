import { test } from "node:test";
import assert from "node:assert/strict";
import { isOneTimePlan, INTRO_USED_SENTENCE } from "../lib/plan-kind.mjs";

test("a trial is a one-time plan (Decision 62)", () => {
  assert.equal(isOneTimePlan("trial"), true);
});

test("a class pack and a drop-in are one-time plans", () => {
  assert.equal(isOneTimePlan("class_pack"), true);
  assert.equal(isOneTimePlan("drop_in"), true);
});

test("a recurring plan is NOT a one-time plan", () => {
  assert.equal(isOneTimePlan("recurring"), false);
});

test("an unknown type is not a one-time plan", () => {
  assert.equal(isOneTimePlan("something_else"), false);
});

test("the intro-once sentence is the exact database sentence", () => {
  assert.equal(
    INTRO_USED_SENTENCE,
    "The intro offer is for first-timers — you've had yours. Choose a pack or membership instead.",
  );
});
