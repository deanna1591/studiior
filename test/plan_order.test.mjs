// Decision 74 — the pure plan-order helper (lib/plan-order.mjs). Zero deps:
//   node --test test/plan_order.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { sortPlans, badgeOk, clampBadge } from "../lib/plan-order.mjs";

const names = (ps) => sortPlans(ps).map((p) => p.name);

test("featured first, then sort_order ascending", () => {
  const ps = [
    { name: "C", featured: false, sort_order: 3, status: "active" },
    { name: "A", featured: true, sort_order: 2, status: "active" },
    { name: "B", featured: false, sort_order: 1, status: "active" },
    { name: "F", featured: true, sort_order: 1, status: "active" },
  ];
  // Featured block first, ordered by sort_order (F=1, A=2); then the rest (B=1, C=3).
  assert.deepEqual(names(ps), ["F", "A", "B", "C"]);
});

test("archived plans sort last whatever their sort_order or featured flag", () => {
  const ps = [
    { name: "arch-featured", featured: true, sort_order: 0, status: "archived" },
    { name: "live", featured: false, sort_order: 9, status: "active" },
    { name: "arch", featured: false, sort_order: 1, status: "archived" },
  ];
  // Live first; within the archived tier featured still sorts first (immaterial
  // — archived plans are never shown featured to members).
  assert.deepEqual(names(ps), ["live", "arch-featured", "arch"]);
});

test("sortPlans does not mutate its input", () => {
  const ps = [
    { name: "B", featured: false, sort_order: 2, status: "active" },
    { name: "A", featured: true, sort_order: 1, status: "active" },
  ];
  const before = ps.map((p) => p.name);
  sortPlans(ps);
  assert.deepEqual(ps.map((p) => p.name), before);
});

test("missing fields are tolerated (no featured / no sort_order / no status)", () => {
  const ps = [
    { name: "X", sort_order: 2 },
    { name: "Y", featured: true },
    { name: "Z", sort_order: 1 },
  ];
  // Y is featured (first); then Z (0-default < 1? Z=1, X=2) -> Y, Z, X.
  assert.deepEqual(names(ps), ["Y", "Z", "X"]);
});

test("badgeOk / clampBadge honour the 24-char ceiling", () => {
  assert.equal(badgeOk(null), true);
  assert.equal(badgeOk(undefined), true);
  assert.equal(badgeOk("Most popular"), true);
  assert.equal(badgeOk("x".repeat(24)), true);
  assert.equal(badgeOk("x".repeat(25)), false);

  assert.equal(clampBadge(""), null);
  assert.equal(clampBadge("   "), null);
  assert.equal(clampBadge("  Best value  "), "Best value");
  assert.equal(clampBadge("x".repeat(30)).length, 24);
  assert.equal(clampBadge(null), null);
});
