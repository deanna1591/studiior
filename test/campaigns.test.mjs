import { test } from "node:test";
import assert from "node:assert/strict";
import { conditionLabels, cadenceLine, quietBlocked } from "../lib/campaigns.mjs";
import { shouldStackAction } from "../lib/row-layout.mjs";

test("112 conditionLabels: one clause per key, stable order", () => {
  assert.deepEqual(conditionLabels({ free_done: true, has_plan: false }),
    ["has no plan", "took a free class"]);
  assert.deepEqual(conditionLabels({ has_plan: true, class_types_min: 1, class_types_max: 1 }),
    ["has a plan", "tried at least 1", "tried at most 1"]);
  assert.deepEqual(conditionLabels({ never_booked: true, joined_min_days: 7 }),
    ["never booked", "signed up over 7 days ago"]);
  assert.deepEqual(conditionLabels({}), []);
  assert.deepEqual(conditionLabels(null), []);
});

test("112 cadenceLine: weekly/monthly summary", () => {
  assert.equal(cadenceLine({ cadence_weeks: 1, max_weekly: 5, monthly_mode: "monthly" }),
    "Every week, up to 5, then monthly");
  assert.equal(cadenceLine({ cadence_weeks: 2, monthly_mode: "stop" }), "Every 2 weeks, then stop");
  assert.equal(cadenceLine({}), "Every week, then stop");
});

test("112 quietBlocked: the 3-day rule", () => {
  const now = 1_000_000_000_000;
  assert.equal(quietBlocked(null, now), false);                 // never emailed
  assert.equal(quietBlocked(now - 1 * 86400000, now), true);    // 1 day ago
  assert.equal(quietBlocked(now - 2 * 86400000, now), true);    // 2 days ago
  assert.equal(quietBlocked(now - 4 * 86400000, now), false);   // 4 days ago
});

test("22(d) shouldStackAction: multi-word or held drops to its own line", () => {
  assert.equal(shouldStackAction("Book"), false);               // one word stays inline
  assert.equal(shouldStackAction("Join waitlist"), true);       // two words stack
  assert.equal(shouldStackAction("Book", { booked: true }), true);
  assert.equal(shouldStackAction("Book", { held: true }), true);
  assert.equal(shouldStackAction("Book", { waiting: true }), true);
  assert.equal(shouldStackAction(""), false);
  assert.equal(shouldStackAction(null), false);
});
