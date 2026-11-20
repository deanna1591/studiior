import { readdirSync, readFileSync } from "node:fs";
import { test } from "node:test";
import assert from "node:assert/strict";
import { isOneTimePlan, isOnlineBuyable, INTRO_USED_SENTENCE } from "../lib/plan-kind.mjs";

test("a recurring plan is online-buyable (Decision 66) but NOT one-time", () => {
  assert.equal(isOnlineBuyable("recurring"), true);
  assert.equal(isOneTimePlan("recurring"), false);
});

test("the one-time plans are all online-buyable", () => {
  for (const t of ["class_pack", "drop_in", "trial"]) assert.equal(isOnlineBuyable(t), true);
});

test("an unknown type is not online-buyable", () => {
  assert.equal(isOnlineBuyable("something_else"), false);
});

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

test("the intro-once sentence is exactly what the database raises", () => {
  assert.equal(INTRO_USED_SENTENCE, "The intro offer is for first-timers and you have had yours. Choose a pack or membership instead.");
  // The newest migration defining each raising function must carry the same
  // words (single quotes doubled in SQL), so app and database cannot drift.
  const dir = new URL("../supabase/migrations/", import.meta.url).pathname;
  const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
  for (const fn of ["activate_purchase", "xendit_begin_purchase"]) {
    const re = new RegExp(`(create|CREATE)\\s+(or\\s+replace\\s+)?(function|FUNCTION)\\s+(public\\.)?${fn}\\(`, "i");
    const newest = files.filter((f) => re.test(readFileSync(dir + f, "utf8"))).pop();
    assert.ok(newest, `no migration defines ${fn}`);
    assert.ok(readFileSync(dir + newest, "utf8").includes(INTRO_USED_SENTENCE.replace(/'/g, "''")),
      `${newest} (${fn}) does not raise the app's sentence`);
  }
});
