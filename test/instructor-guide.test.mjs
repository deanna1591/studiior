// Decision 85 — the Studio Guide content (lib/instructor-guide.mjs). Runs with
// zero deps:  node --test test/instructor-guide.test.mjs
//
// It guards the record against drift: every section has a title, lines, and a
// go path that is a real instructor route; the content is platform-neutral
// (no em dash, no currency symbol, no studio name other than the {studio_name}
// token); and every hint key is one the writer (instructor_guide_mark) knows.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { INTRO_CARDS, HINTS, SECTIONS, fillStudio } from "../lib/instructor-guide.mjs";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const routeFile = (go) => {
  // "/instructor/schedule" -> app/member/instructor/schedule/page.tsx
  const rest = go.replace(/^\/instructor\/?/, "");
  const dir = rest ? join("app/member/instructor", rest) : "app/member/instructor";
  return join(root, dir, "page.tsx");
};

// Every string the guide shows, so the platform-neutral checks cover all of it.
const allStrings = [
  ...INTRO_CARDS.flatMap((c) => [c.title, c.body]),
  ...Object.values(HINTS),
  ...SECTIONS.flatMap((s) => [s.title, ...s.lines]),
];

test("every section has a title, lines, and a go path that exists in the app", () => {
  assert.ok(SECTIONS.length >= 1);
  for (const s of SECTIONS) {
    assert.equal(typeof s.title, "string");
    assert.ok(s.title.trim().length > 0, `empty section title`);
    assert.ok(Array.isArray(s.lines) && s.lines.length > 0, `${s.title}: no lines`);
    for (const line of s.lines) {
      assert.equal(typeof line, "string");
      assert.ok(line.trim().length > 0, `${s.title}: empty line`);
    }
    assert.ok(s.go.startsWith("/instructor"), `${s.title}: go is not an instructor path`);
    assert.ok(existsSync(routeFile(s.go)), `${s.title}: go path ${s.go} has no route (${routeFile(s.go)})`);
  }
});

test("there are exactly five intro cards, card one carries the token", () => {
  assert.equal(INTRO_CARDS.length, 5);
  for (const c of INTRO_CARDS) {
    assert.ok(c.title.trim().length > 0 && c.body.trim().length > 0);
  }
  assert.ok(INTRO_CARDS[0].title.includes("{studio_name}"), "card one must carry {studio_name}");
  assert.equal(fillStudio(INTRO_CARDS[0].title, "Reform Collective"), "Welcome to Reform Collective");
});

test("the content is platform-neutral: no em dash, no currency symbol", () => {
  for (const s of allStrings) {
    assert.ok(!s.includes("—"), `em dash in: ${s}`);
    assert.ok(!/[₱$€£¥₹]/.test(s), `currency symbol in: ${s}`);
  }
});

test("no studio name other than the {studio_name} token", () => {
  for (const s of allStrings) {
    // The only brace-token anywhere is {studio_name}.
    for (const m of s.match(/\{[^}]*\}/g) ?? []) {
      assert.equal(m, "{studio_name}", `unexpected token ${m} in: ${s}`);
    }
    // And no tenant name leaks in as a literal.
    assert.ok(!/reform/i.test(s), `a studio name literal in: ${s}`);
  }
});

test("every hint key is one of the three the writer knows", () => {
  const keys = Object.keys(HINTS);
  assert.deepEqual(keys.sort(), ["cover", "pay", "roster"]);
  for (const v of Object.values(HINTS)) assert.ok(v.trim().length > 0);
});
