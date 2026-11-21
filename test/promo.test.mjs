// Decision 117 — the sale price rounding and the display strings.
//   node --test test/promo.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { salePriceCents, promoTag, saleAppliedLine, pctOffLabel, withPrice } from "../lib/promo.mjs";

test("sale price rounds half up to the whole unit, like promo_sale_cents", () => {
  assert.equal(salePriceCents(140000, 15), 119000);
  assert.equal(salePriceCents(99950, 20), 80000);   // 799.60 -> 800
  assert.equal(salePriceCents(1000, 15), 900);      // 8.50 -> 9 (half up)
  assert.equal(salePriceCents(999, 15), 800);       // 8.49 -> 8
  assert.equal(salePriceCents(160000, 25), 120000);
});

test("the tag and the sell-sheet line", () => {
  const p = { plan_id: "x", list_cents: 140000, price_cents: 119000, discount_cents: 21000, currency: "PHP",
              promotion_id: "p", promotion_name: "Holiday Sale", pct: 15, ends_on: "2026-12-28", ends_label: "Mon 28 Dec" };
  assert.equal(promoTag(p), "Holiday Sale, 15% off until Mon 28 Dec");
  assert.equal(saleAppliedLine(p), "Sale price applied: Holiday Sale, 15% off");
  assert.equal(pctOffLabel(15), "15% off");
  assert.equal(promoTag({ ...p, promotion_id: null }), null);
  assert.equal(saleAppliedLine(null), null);
  assert.equal(pctOffLabel(null), null);
});

test("withPrice overlays the sale price and keeps the list price", () => {
  const prices = new Map([["a", { plan_id: "a", list_cents: 140000, price_cents: 119000, discount_cents: 21000,
    currency: "PHP", promotion_id: "p", promotion_name: "Sale", pct: 15, ends_on: "2026-12-28", ends_label: "Mon 28 Dec" }]]);
  const on = withPrice({ id: "a", price_cents: 140000 }, prices);
  assert.equal(on.price_cents, 119000);
  assert.equal(on.list_cents, 140000);
  assert.equal(on.promo.pct, 15);
  const off = withPrice({ id: "b", price_cents: 50000 }, prices);
  assert.equal(off.price_cents, 50000);
  assert.equal(off.list_cents, 50000);
  assert.equal(off.promo, null);
});

test("no em dash in any string", () => {
  const p = { promotion_id: "p", promotion_name: "Sale", pct: 10, ends_label: "Mon 28 Dec" };
  for (const s of [promoTag(p), saleAppliedLine(p), pctOffLabel(10)]) assert.ok(!s.includes("—"));
});
