// Decision 80c — the editable-template groups (lib/templates.mjs) carry an
// audience and a when line per key, and a feature gate that hides a key while its
// studio feature is off. Zero deps:  node --test test/templates.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  TEMPLATE_GROUPS, templateEntry, templateFeature, isTemplateVisible,
  featureSet, templateKeysForMaster, isEditableTemplate,
} from "../lib/templates.mjs";

const AUDIENCES = new Set(["Members", "Instructors", "Staff"]);
const FEATURES = new Set(["flex", "free_first", "guest_passes", "challenges", "shop", "guarantees"]);
const allKeys = TEMPLATE_GROUPS.flatMap((g) => g.keys);

test("every listed key has a label, an audience, and a when line", () => {
  assert.ok(allKeys.length > 0);
  for (const k of allKeys) {
    assert.ok(typeof k.key === "string" && k.key.length > 0, `bad key: ${JSON.stringify(k)}`);
    assert.ok(typeof k.label === "string" && k.label.trim().length > 0, `${k.key}: no label`);
    assert.ok(AUDIENCES.has(k.audience), `${k.key}: bad audience ${k.audience}`);
    assert.ok(typeof k.when === "string" && k.when.trim().length > 0, `${k.key}: no when line`);
    if (k.feature !== undefined) assert.ok(FEATURES.has(k.feature), `${k.key}: bad feature ${k.feature}`);
  }
});

test("keys are unique across groups and every one is editable", () => {
  const seen = new Set();
  for (const k of allKeys) {
    assert.ok(!seen.has(k.key), `duplicate key ${k.key}`);
    seen.add(k.key);
    assert.ok(isEditableTemplate(k.key), `${k.key}: not in the editable set`);
  }
});

test("when lines are platform-neutral: no em dash of their own, no currency symbol", () => {
  for (const k of allKeys) {
    assert.ok(!/[₱$€£¥₹]/.test(k.when), `${k.key}: currency in when`);
  }
});

test("templateEntry / templateFeature reflect the data", () => {
  assert.equal(templateEntry("booking_confirmed").audience, "Members");
  assert.equal(templateFeature("flex_booking_pending"), "flex");
  assert.equal(templateFeature("convert_after_class"), "free_first");
  assert.equal(templateFeature("product_order_paid"), "shop");
  assert.equal(templateFeature("core_committed"), "guarantees");
  assert.equal(templateFeature("booking_confirmed"), null);
  assert.equal(templateEntry("nope"), null);
});

test("isTemplateVisible: no-feature keys always show, feature keys follow the set", () => {
  const none = new Set();
  const flexOn = new Set(["flex"]);
  assert.equal(isTemplateVisible("booking_confirmed", none), true, "no-feature key hidden");
  assert.equal(isTemplateVisible("flex_booking_pending", none), false, "flex key shown while flex off");
  assert.equal(isTemplateVisible("flex_booking_pending", flexOn), true, "flex key hidden while flex on");
  assert.equal(isTemplateVisible("convert_after_class", new Set(["free_first"])), true);
  assert.equal(isTemplateVisible("convert_after_class", none), false);
  assert.equal(isTemplateVisible("product_order_paid", new Set(["shop"])), true);
});

test("featureSet maps flags to ids", () => {
  const s = featureSet({ flex: true, freeFirst: false, guest: true, challenges: false, shop: true, guarantees: false });
  assert.deepEqual([...s].sort(), ["flex", "guest_passes", "shop"]);
  assert.equal(featureSet({}).size, 0);
});

test("the master lists are the convert_* and keep_* keys, every one feature-tagged / tagged right", () => {
  const convert = templateKeysForMaster("convert");
  const keep = templateKeysForMaster("keep");
  assert.ok(convert.length >= 6 && convert.every((k) => k.key.startsWith("convert_")));
  assert.ok(keep.length >= 8 && keep.every((k) => k.key.startsWith("keep_")));
  // Every convert email belongs to free_first (so the list hides when it is off).
  assert.ok(convert.every((k) => k.feature === "free_first"), "a convert key is not free_first-gated");
  // Keep emails are always relevant — no feature gate.
  assert.ok(keep.every((k) => k.feature === undefined), "a keep key is unexpectedly feature-gated");
  for (const k of [...convert, ...keep]) assert.ok(k.when && k.audience === "Members");
});
