// Decision 22 — canForceCommit: which "Run anyway" label the staff page shows.
// Run: node --test test/force-commit.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { canForceCommit, forceCommitMinimum } from "../lib/force-commit.mjs";

const NOW = 1_000_000_000_000;
const FUTURE = NOW + 3_600_000; // 1h out
const PAST = NOW - 3_600_000;

const S = { guaranteesEnabled: true, flexEnabled: true, coreMin: 3, flexMin: 2, nowMs: NOW };
const flexOcc = { flex: true, guaranteeTier: "flex", minimumBookings: 3, committedAt: null,
  status: "scheduled", startsMs: FUTURE, bookedCount: 2 };
const coreOcc = { flex: false, guaranteeTier: "core", minimumBookings: null, committedAt: null,
  status: "scheduled", startsMs: FUTURE, bookedCount: 1 };

test("flex, scheduled, uncommitted, future → Run anyway (regardless of headcount)", () => {
  assert.equal(canForceCommit(flexOcc, S), "run_anyway");
  assert.equal(canForceCommit({ ...flexOcc, bookedCount: 5 }, S), "run_anyway");
  assert.equal(forceCommitMinimum(flexOcc, S), 3);           // occurrence override
  assert.equal(forceCommitMinimum({ ...flexOcc, minimumBookings: null }, S), 2); // studio flex min
});

test("flex with flex OFF behaves as always → none", () => {
  assert.equal(canForceCommit(flexOcc, { ...S, flexEnabled: false }), "none");
});

test("core, min > 1, not yet reached → Run anyway; names the core minimum", () => {
  assert.equal(canForceCommit(coreOcc, S), "run_anyway");
  assert.equal(forceCommitMinimum(coreOcc, S), 3);
});

test("core already at/over the minimum → none", () => {
  assert.equal(canForceCommit({ ...coreOcc, bookedCount: 3 }, S), "none");
  assert.equal(canForceCommit({ ...coreOcc, bookedCount: 4 }, S), "none");
});

test("core with minimum 1 → none (a core class runs anyway)", () => {
  assert.equal(canForceCommit({ ...coreOcc, bookedCount: 0 }, { ...S, coreMin: 1 }), "none");
});

test("core with guarantees OFF behaves as always → none", () => {
  assert.equal(canForceCommit(coreOcc, { ...S, guaranteesEnabled: false }), "none");
});

test("not-scheduled, committed, or past → none", () => {
  assert.equal(canForceCommit({ ...flexOcc, status: "cancelled" }, S), "none");
  assert.equal(canForceCommit({ ...flexOcc, committedAt: "2026-01-01T00:00:00Z" }, S), "none");
  assert.equal(canForceCommit({ ...flexOcc, startsMs: PAST }, S), "none");
  assert.equal(canForceCommit({ ...flexOcc, startsMs: NOW }, S), "none"); // exactly now is not future
});

test("explicit 'always' tier → none", () => {
  assert.equal(canForceCommit({ ...coreOcc, flex: false, guaranteeTier: "always" }, S), "none");
});
