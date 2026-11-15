// node --test test/tier-tint.test.mjs
// Decision 22 amendment: a core (or always-runs) class is tinted; flex is not.

import { test } from "node:test";
import assert from "node:assert/strict";
import { effectiveTier, isCore, showsAlwaysRuns, ALWAYS_RUNS_CHIP } from "../lib/tier-tint.mjs";

test("effectiveTier — the coalesce order mirrors occurrence_guarantee_run", () => {
  // occurrence tier wins
  assert.equal(effectiveTier({ tier: "always", flex: true, seriesFlex: true }), "always");
  assert.equal(effectiveTier({ tier: "flex" }), "flex");
  assert.equal(effectiveTier({ tier: "core" }), "core");
  // then occurrence flex
  assert.equal(effectiveTier({ flex: true, seriesTier: "core" }), "flex");
  // then series tier
  assert.equal(effectiveTier({ seriesTier: "always" }), "always");
  // then series flex
  assert.equal(effectiveTier({ seriesFlex: true }), "flex");
  // then core
  assert.equal(effectiveTier({}), "core");
  assert.equal(effectiveTier({ tier: null, flex: false, seriesTier: null, seriesFlex: false }), "core");
});

test("isCore — true for core and always, false for flex", () => {
  assert.equal(isCore({ tier: "core" }), true);
  assert.equal(isCore({ tier: "always" }), true);
  assert.equal(isCore({}), true); // default core
  assert.equal(isCore({ seriesTier: "always" }), true);
  assert.equal(isCore({ tier: "flex" }), false);
  assert.equal(isCore({ flex: true }), false);
  assert.equal(isCore({ seriesFlex: true }), false);
});

test("showsAlwaysRuns — only when guarantees on AND core", () => {
  assert.equal(showsAlwaysRuns(true, { tier: "core" }), true);
  assert.equal(showsAlwaysRuns(true, { tier: "always" }), true);
  assert.equal(showsAlwaysRuns(true, { tier: "flex" }), false);
  assert.equal(showsAlwaysRuns(false, { tier: "core" }), false); // guarantees off: no tint
  assert.equal(showsAlwaysRuns(false, { tier: "always" }), false);
});

test("the chip label has no em dash and reads plainly", () => {
  assert.equal(ALWAYS_RUNS_CHIP, "Always runs");
  assert.ok(!/—/.test(ALWAYS_RUNS_CHIP));
});
