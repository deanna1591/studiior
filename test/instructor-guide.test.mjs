// Decision 85 (+ amendment (a)) — the Studio Guide content
// (lib/instructor-guide.mjs) and its ui registry (lib/guide-ui-registry.mjs).
// Runs with zero deps:  node --test test/instructor-guide.test.mjs
//
// It guards the record against drift: every section has a title, steps, and a
// go path that is a real instructor route; every INLINE marker the content names
// ([tab X] / [button X]) resolves to a registry key, and every [screen X] step
// resolves to a screen picture; NO raw bracket survives into what the screen
// draws — asserted on splitGuideText, the ONE parser the renderer
// (components/instructor/guide-ui.tsx GuideText) renders from, so a text run
// never contains "[" or "]" and every ref run resolves to a chip; and the content
// is platform-neutral (no em dash, no currency, no studio name but {studio_name}).
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { INTRO_CARDS, HINTS, SECTIONS, fillStudio, splitGuideText } from "../lib/instructor-guide.mjs";
import { TABS, BUTTONS, SCREENS } from "../lib/guide-ui-registry.mjs";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const routeFile = (go) => {
  // "/instructor/schedule" -> app/member/instructor/schedule/page.tsx
  const rest = go.replace(/^\/instructor\/?/, "");
  const dir = rest ? join("app/member/instructor", rest) : "app/member/instructor";
  return join(root, dir, "page.tsx");
};

// Every string the guide renders as a line (carries its chips inline), with where
// it came from — the exact input to GuideText.
const lines = [
  ...INTRO_CARDS.map((c) => [`intro card "${c.title}"`, c.body]),
  ...Object.entries(HINTS).map(([k, h]) => [`hint ${k}`, h.text]),
  ...SECTIONS.flatMap((s) =>
    s.steps.filter((st) => typeof st.text === "string").map((st) => [`section "${s.title}"`, st.text])),
];
// Every screen picture the content names.
const screenRefs = SECTIONS.flatMap((s) =>
  s.steps.filter((st) => st.screen).map((st) => [`section "${s.title}"`, st.screen]));

// Every non-line string, for the platform-neutral checks (titles / captions /
// Important / intro — these carry no markers).
const plainStrings = [
  ...INTRO_CARDS.map((c) => c.title),
  ...SECTIONS.flatMap((s) => [
    s.title,
    ...(s.important ? [s.important] : []),
    ...(s.intro ? [s.intro] : []),
    ...s.steps.filter((st) => st.caption).map((st) => st.caption),
  ]),
];

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

test("every inline marker resolves to a registry key, and nothing bracketed survives the parser", () => {
  for (const [where, text] of lines) {
    const runs = splitGuideText(text);
    for (const run of runs) {
      if (run.t === "text") {
        // A text run is rendered verbatim — a stray bracket here would reach the
        // DOM. There must be none: every "[" began a valid marker the parser took.
        assert.ok(!run.value.includes("["), `${where}: a "[" survives the parser in text: ${run.value}`);
        assert.ok(!run.value.includes("]"), `${where}: a "]" survives the parser in text: ${run.value}`);
      } else {
        assert.ok(run.kind === "tab" || run.kind === "button", `${where}: bad ref kind ${run.kind}`);
        const reg = run.kind === "tab" ? TABS : BUTTONS;
        assert.ok(Object.prototype.hasOwnProperty.call(reg, run.key), `${where}: ${run.kind} "${run.key}" is not in the registry`);
      }
    }
  }
  for (const [where, key] of screenRefs) {
    assert.ok(Object.prototype.hasOwnProperty.call(SCREENS, key), `${where}: screen "${key}" is not in the registry`);
  }
  // Every tab in the registry resolves to an icon; every button to a known variant.
  for (const [key, t] of Object.entries(TABS)) {
    assert.ok(t && typeof t.icon === "string" && t.icon.length > 0, `tab ${key}: no icon`);
  }
  for (const [key, v] of Object.entries(BUTTONS)) {
    assert.ok(["solid", "tint", "outline"].includes(v), `button ${key}: bad variant ${v}`);
  }
});

test("the parser round-trips: joining the runs back yields the original line", () => {
  for (const [where, text] of lines) {
    const rebuilt = splitGuideText(text)
      .map((r) => (r.t === "text" ? r.value : `[${r.kind} ${r.key}]`))
      .join("");
    assert.equal(rebuilt, text, `${where}: parser does not round-trip`);
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
  for (const s of [...plainStrings, ...lines.map(([, t]) => t)]) {
    assert.ok(!s.includes("—"), `em dash in: ${s}`);
    assert.ok(!/[₱$€£¥₹]/.test(s), `currency symbol in: ${s}`);
  }
});

test("no studio name other than the {studio_name} token", () => {
  for (const s of [...plainStrings, ...lines.map(([, t]) => t)]) {
    for (const m of s.match(/\{[^}]*\}/g) ?? []) {
      assert.equal(m, "{studio_name}", `unexpected token ${m} in: ${s}`);
    }
    assert.ok(!/reform/i.test(s), `a studio name literal in: ${s}`);
  }
  // A plain (non-line) string carries no markers of its own — titles, captions,
  // Important and intro are rendered as text, so a bracket there WOULD reach the DOM.
  for (const s of plainStrings) {
    assert.ok(!/\[(tab|button|screen)\b/i.test(s), `raw bracket notation in a plain string: ${s}`);
  }
});

test("every hint key is one of the three the writer knows, each with text", () => {
  const keys = Object.keys(HINTS);
  assert.deepEqual(keys.sort(), ["cover", "pay", "roster"]);
  for (const v of Object.values(HINTS)) {
    assert.ok(v.text.trim().length > 0);
  }
});
