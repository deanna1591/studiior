// Decision 54 (+ guarantees/flex visibility) — the instructor core/flex tag rule
// (lib/class-tag.mjs). Zero deps:  node --test test/class-tag.test.mjs
//
// The tag shows only the tier the studio runs: both off = nothing; only one on =
// only that tier; a tier whose switch is off is effectively "always" and shows
// nothing; "always" never shows.
import { test } from "node:test";
import assert from "node:assert/strict";
import { classTagText } from "../lib/class-tag.mjs";

const core = (f = {}) => classTagText({ tier: "core", guaranteesEnabled: false, flexEnabled: false, ...f });
const flex = (f = {}) => classTagText({ tier: "flex", guaranteesEnabled: false, flexEnabled: false, ...f });
const always = (f = {}) => classTagText({ tier: "always", guaranteesEnabled: false, flexEnabled: false, ...f });

test("both switches off — no tag for any tier", () => {
  assert.equal(core().show, false);
  assert.equal(flex().show, false);
  assert.equal(always().show, false);
});

test("guarantees on only — core is tagged, flex and always are not", () => {
  assert.deepEqual(core({ guaranteesEnabled: true }), { show: true, text: "core", isFlex: false });
  assert.equal(flex({ guaranteesEnabled: true }).show, false, "flex-tier shows nothing while flex is off");
  assert.equal(always({ guaranteesEnabled: true }).show, false, "always never shows");
});

test("flex on only — flex is tagged, core and always are not", () => {
  assert.equal(core({ flexEnabled: true }).show, false, "core-tier shows nothing while guarantees is off");
  const f = flex({ flexEnabled: true });
  assert.equal(f.show, true);
  assert.equal(f.isFlex, true);
  assert.equal(f.text, "flex");
  assert.equal(always({ flexEnabled: true }).show, false);
});

test("both on — core and flex each tagged, always not; flex sub-states carry", () => {
  assert.equal(core({ guaranteesEnabled: true, flexEnabled: true }).text, "core");
  assert.equal(flex({ guaranteesEnabled: true, flexEnabled: true }).text, "flex");
  assert.equal(always({ guaranteesEnabled: true, flexEnabled: true }).show, false);
  assert.equal(flex({ flexEnabled: true, committed: true }).text, "flex · confirmed");
  assert.equal(flex({ flexEnabled: true, flexDeadlineShort: "8:00 PM Mon" }).text, "flex · decided by 8:00 PM Mon");
  assert.equal(flex({ flexEnabled: true, cancelled: true }).text, "flex");
});

test("flex via the boolean (flex=true) with tier null behaves like a flex tier", () => {
  assert.equal(classTagText({ tier: null, flex: true, flexEnabled: false }).show, false);
  assert.equal(classTagText({ tier: null, flex: true, flexEnabled: true }).text, "flex");
});

test("defaults: with no switches passed, the old behaviour (both on) holds", () => {
  assert.equal(classTagText({ tier: "core" }).text, "core");
  assert.equal(classTagText({ tier: "flex" }).text, "flex");
});
