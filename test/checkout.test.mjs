import { test } from "node:test";
import assert from "node:assert/strict";
import { checkoutPlanOrder, planHelpLine, checkoutTotalCents } from "../lib/checkout.mjs";

const mk = (id, type, extra = {}) => ({
  id, type, name: id, price_cents: 1000, currency: "PHP",
  credits: null, credits_per_period: null, validity_days: null, billing_interval: null, ...extra,
});

test("checkoutPlanOrder: drop-in first (preselected), then trial, packs, memberships", () => {
  const out = checkoutPlanOrder([
    mk("rec", "recurring"), mk("pack", "class_pack"), mk("drop", "drop_in"), mk("intro", "trial"),
  ]);
  assert.deepEqual(out.map((p) => p.id), ["drop", "intro", "pack", "rec"]);
  assert.equal(out[0].id, "drop"); // element 0 is the preselected default
});

test("checkoutPlanOrder: group and unknown plans are excluded", () => {
  const out = checkoutPlanOrder([mk("g", "group"), mk("drop", "drop_in"), mk("x", "other")]);
  assert.deepEqual(out.map((p) => p.id), ["drop"]);
});

test("checkoutPlanOrder: a used trial drops the intro offer", () => {
  const out = checkoutPlanOrder([mk("drop", "drop_in"), mk("intro", "trial")], { trialUsed: true });
  assert.deepEqual(out.map((p) => p.id), ["drop"]);
});

test("checkoutPlanOrder: the exclusive intro plan is hidden out of window", () => {
  const out = checkoutPlanOrder(
    [mk("drop", "drop_in"), mk("intro", "trial")],
    { introPlanId: "intro", hideExclusiveIntro: true },
  );
  assert.deepEqual(out.map((p) => p.id), ["drop"]);
  // ...and shown when in window
  const inWin = checkoutPlanOrder(
    [mk("drop", "drop_in"), mk("intro", "trial")],
    { introPlanId: "intro", hideExclusiveIntro: false },
  );
  assert.deepEqual(inWin.map((p) => p.id), ["drop", "intro"]);
});

test("checkoutPlanOrder: equal ranks keep incoming order (packs sorted by the query)", () => {
  const out = checkoutPlanOrder([mk("packB", "class_pack"), mk("packA", "class_pack"), mk("drop", "drop_in")]);
  assert.deepEqual(out.map((p) => p.id), ["drop", "packB", "packA"]);
});

test("checkoutPlanOrder: null/empty is []", () => {
  assert.deepEqual(checkoutPlanOrder(null), []);
  assert.deepEqual(checkoutPlanOrder([]), []);
});

test("planHelpLine: each plan type reads from stored fields", () => {
  assert.equal(planHelpLine(mk("d", "drop_in")), "Single class");
  assert.equal(planHelpLine(mk("p", "class_pack", { credits: 10, validity_days: 60 })), "10 classes · use within 60 days");
  assert.equal(planHelpLine(mk("p", "class_pack", { credits: 5 })), "5 classes");
  assert.equal(planHelpLine(mk("t", "trial", { credits: 3, validity_days: 14 })), "3 classes · use within 14 days");
  assert.equal(planHelpLine(mk("t", "trial", { credits: 1 })), "1 class");
  assert.equal(planHelpLine(mk("r", "recurring", { credits_per_period: 8, billing_interval: "month" })), "8 classes each period · one month — renew by hand");
  assert.equal(planHelpLine(mk("r", "recurring", { credits_per_period: null, billing_interval: "month" })), "Unlimited classes · one month — renew by hand");
  assert.equal(planHelpLine(null), "");
});

test("checkoutTotalCents: the chosen plan's price, no discounts", () => {
  assert.equal(checkoutTotalCents(mk("d", "drop_in", { price_cents: 15000 })), 15000);
  assert.equal(checkoutTotalCents(null), 0);
});
