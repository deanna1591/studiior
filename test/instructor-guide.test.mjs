// Decision 85 (+ amendment (a)) — the Studio Guide content
// (lib/instructor-guide.mjs) and its ui registry (lib/guide-ui-registry.mjs).
// Runs with zero deps:  node --test test/instructor-guide.test.mjs
//
// It guards the record against drift: every section has a title, steps, and a
// go path that is a real instructor route; every ui ref the content names has
// an entry in the registry (a missing key fails here, before the build); the
// content is platform-neutral (no em dash, no currency symbol, no studio name
// other than the {studio_name} token); and every hint key is one the writer
// (instructor_guide_mark) knows.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { INTRO_CARDS, HINTS, SECTIONS, fillStudio } from "../lib/instructor-guide.mjs";
import { TABS, BUTTONS, SCREENS } from "../lib/guide-ui-registry.mjs";

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
  ...Object.values(HINTS).map((h) => h.text),
  ...SECTIONS.flatMap((s) => [
    s.title,
    ...(s.important ? [s.important] : []),
    ...(s.intro ? [s.intro] : []),
    ...s.steps.flatMap((st) => [st.text, st.caption].filter(Boolean)),
  ]),
];

// Every inline ref the content names (tab/button), with where it came from.
const inlineRefs = [
  ...INTRO_CARDS.flatMap((c) => (c.refs ?? []).map((r) => [`intro card "${c.title}"`, r])),
  ...Object.entries(HINTS).flatMap(([k, h]) => (h.refs ?? []).map((r) => [`hint ${k}`, r])),
  ...SECTIONS.flatMap((s) => s.steps.flatMap((st) => (st.refs ?? []).map((r) => [`section "${s.title}"`, r]))),
];
// Every screen picture the content names.
const screenRefs = SECTIONS.flatMap((s) =>
  s.steps.filter((st) => st.screen).map((st) => [`section "${s.title}"`, st.screen]));

test("every section has a title, steps, and a go path that exists in the app", () => {
  assert.ok(SECTIONS.length >= 1);
  for (const s of SECTIONS) {
    assert.equal(typeof s.title, "string");
    assert.ok(s.title.trim().length > 0, "empty section title");
    assert.ok(Array.isArray(s.steps) && s.steps.length > 0, `${s.title}: no steps`);
    for (const st of s.steps) {
      // A step is either a text instruction or a screen picture, not nothing.
      const isScreen = typeof st.screen === "string" && st.screen.length > 0;
      const isText = typeof st.text === "string" && st.text.trim().length > 0;
      assert.ok(isScreen || isText, `${s.title}: a step is neither text nor screen`);
      if (isScreen) assert.ok(st.caption && st.caption.trim().length > 0, `${s.title}: screen ${st.screen} has no caption`);
    }
    assert.ok(s.go.startsWith("/instructor"), `${s.title}: go is not an instructor path`);
    assert.ok(existsSync(routeFile(s.go)), `${s.title}: go path ${s.go} has no route (${routeFile(s.go)})`);
  }
});

test("every ui ref the content names has an entry in the registry", () => {
  for (const [where, r] of inlineRefs) {
    assert.ok(r && (r.kind === "tab" || r.kind === "button"), `${where}: bad inline ref ${JSON.stringify(r)}`);
    const reg = r.kind === "tab" ? TABS : BUTTONS;
    assert.ok(Object.prototype.hasOwnProperty.call(reg, r.key), `${where}: ${r.kind} "${r.key}" is not in the registry`);
  }
  for (const [where, key] of screenRefs) {
    assert.ok(Object.prototype.hasOwnProperty.call(SCREENS, key), `${where}: screen "${key}" is not in the registry`);
  }
  // Every tab in the registry also resolves to one of the shell's icons — a tab
  // key with no icon would render a blank chip.
  for (const [key, t] of Object.entries(TABS)) {
    assert.ok(t && typeof t.icon === "string" && t.icon.length > 0, `tab ${key}: no icon`);
  }
  for (const [key, v] of Object.entries(BUTTONS)) {
    assert.ok(["solid", "tint", "outline"].includes(v), `button ${key}: bad variant ${v}`);
  }
});

test("there are exactly five intro cards, card one carries the token", () => {
  assert.equal(INTRO_CARDS.length, 5);
  for (const c of INTRO_CARDS) {
    assert.ok(c.title.trim().length > 0 && c.body.trim().length > 0);
    assert.ok(Array.isArray(c.refs), `${c.title}: refs must be an array`);
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

test("no studio name other than the {studio_name} token, and no bracket notation", () => {
  for (const s of allStrings) {
    // The only brace-token anywhere is {studio_name}.
    for (const m of s.match(/\{[^}]*\}/g) ?? []) {
      assert.equal(m, "{studio_name}", `unexpected token ${m} in: ${s}`);
    }
    // No tenant name leaks in as a literal.
    assert.ok(!/reform/i.test(s), `a studio name literal in: ${s}`);
    // No raw [tab X] / [button X] / [screen X] notation survives into a string.
    assert.ok(!/\[(tab|button|screen)\b/i.test(s), `raw bracket notation in: ${s}`);
  }
});

test("every hint key is one of the three the writer knows, each with text", () => {
  const keys = Object.keys(HINTS);
  assert.deepEqual(keys.sort(), ["cover", "pay", "roster"]);
  for (const v of Object.values(HINTS)) {
    assert.ok(v.text.trim().length > 0);
    assert.ok(Array.isArray(v.refs), "hint refs must be an array");
  }
});
