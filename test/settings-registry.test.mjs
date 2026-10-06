// Decision 71 — the settings registry is the backbone (home search, group-page
// sections, audit rule 3). This guards its shape and the search ranking.
//
//   node --test test/settings-registry.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { GROUPS, SETTINGS, searchSettings } from "../lib/settings-registry.mjs";

test("every entry has a non-empty label", () => {
  for (const s of SETTINGS) {
    assert.ok(typeof s.label === "string" && s.label.trim().length > 0, `empty label: ${s.id}`);
  }
});

test("every entry has 2–4 synonyms", () => {
  for (const s of SETTINGS) {
    assert.ok(Array.isArray(s.synonyms), `no synonyms: ${s.id}`);
    assert.ok(s.synonyms.length >= 2 && s.synonyms.length <= 4,
      `${s.id} has ${s.synonyms.length} synonyms (want 2–4)`);
  }
});

test("every entry's page exists under app/staff", () => {
  for (const s of SETTINGS) {
    assert.ok(typeof s.page === "string" && s.page.startsWith("/"), `bad page: ${s.id}`);
    const dir = `app/staff${s.page}`;
    assert.ok(existsSync(dir), `${s.id} page ${s.page} → ${dir} does not exist`);
  }
});

test("ids are unique", () => {
  const seen = new Set();
  for (const s of SETTINGS) {
    assert.ok(!seen.has(s.id), `duplicate id: ${s.id}`);
    seen.add(s.id);
  }
});

test("every group has at least one entry, and every entry's group exists", () => {
  const groupIds = new Set(GROUPS.map((g) => g.id));
  for (const g of GROUPS) {
    assert.ok(SETTINGS.some((s) => s.group === g.id), `group ${g.id} has no entries`);
  }
  for (const s of SETTINGS) {
    assert.ok(groupIds.has(s.group), `${s.id} has unknown group ${s.group}`);
  }
});

test("every group section anchor is used by at least one entry", () => {
  for (const g of GROUPS) {
    for (const sec of g.sections) {
      assert.ok(
        SETTINGS.some((s) => s.group === g.id && s.anchor === sec.anchor),
        `group ${g.id} section ${sec.anchor} has no entry`,
      );
    }
  }
});

test('searchSettings("cut") returns Cancellation cut-off first', () => {
  const r = searchSettings("cut");
  assert.ok(r.length > 0, "no matches for cut");
  assert.equal(r[0].label, "Cancellation cut-off");
});

test('searchSettings("gcash") returns the Xendit entry', () => {
  const r = searchSettings("gcash");
  assert.ok(r.some((s) => s.id === "xendit"), "gcash did not match Xendit");
});

test('searchSettings("") is empty', () => {
  assert.deepEqual(searchSettings(""), []);
  assert.deepEqual(searchSettings("   "), []);
});

test("searchSettings caps at 8", () => {
  // "a" matches many via label/synonym/group; must never exceed 8.
  assert.ok(searchSettings("a").length <= 8);
});
