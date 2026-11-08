// Decision 93 slice 1 — brand kit spec validation + defaults. Zero deps:
//   node --test test/brand-kit.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  isValidSpec, parseBrandSpec, defaultSpec, BRAND_FONTS,
} from "../lib/brand-kit.mjs";

const GOOD = {
  colors: { background: "#FAFAF7", surface: "#FFFFFF", ink: "#14170E", accent: "#B85C38", secondary: "#57534E" },
  display_font: "Playfair Display", body_font: "Manrope",
  layout: "poster", radius: "large", tone: "Editorial and warm.",
  logo_placement: "top-centre", background_treatment: "soft",
};

test("isValidSpec: a complete, correct spec is valid", () => {
  assert.equal(isValidSpec(GOOD), true);
});

test("isValidSpec: a missing colour is invalid", () => {
  const s = JSON.parse(JSON.stringify(GOOD)); delete s.colors.accent;
  assert.equal(isValidSpec(s), false);
});

test("isValidSpec: a 3-digit or non-hex colour is invalid", () => {
  assert.equal(isValidSpec({ ...GOOD, colors: { ...GOOD.colors, ink: "#fff" } }), false);
  assert.equal(isValidSpec({ ...GOOD, colors: { ...GOOD.colors, ink: "red" } }), false);
});

test("isValidSpec: a font not in the vendored list is invalid", () => {
  assert.equal(isValidSpec({ ...GOOD, display_font: "Comic Sans" }), false);
  assert.equal(isValidSpec({ ...GOOD, body_font: "Arial" }), false);
});

test("isValidSpec: each enum is checked", () => {
  assert.equal(isValidSpec({ ...GOOD, layout: "carousel" }), false);
  assert.equal(isValidSpec({ ...GOOD, radius: "medium" }), false);
  assert.equal(isValidSpec({ ...GOOD, logo_placement: "top-right" }), false);
  assert.equal(isValidSpec({ ...GOOD, background_treatment: "gradient" }), false);
});

test("isValidSpec: a tone over 200 chars is invalid", () => {
  assert.equal(isValidSpec({ ...GOOD, tone: "x".repeat(201) }), false);
  assert.equal(isValidSpec({ ...GOOD, tone: "x".repeat(200) }), true);
});

test("parseBrandSpec: clean JSON → the spec", () => {
  assert.deepEqual(parseBrandSpec(JSON.stringify(GOOD)), GOOD);
});

test("parseBrandSpec: a ```json fence is tolerated", () => {
  assert.deepEqual(parseBrandSpec("```json\n" + JSON.stringify(GOOD) + "\n```"), GOOD);
});

test("parseBrandSpec: leading prose before the object is tolerated", () => {
  assert.deepEqual(parseBrandSpec("Here is the spec:\n" + JSON.stringify(GOOD)), GOOD);
});

test("parseBrandSpec: extra keys the model invents are stripped, not kept", () => {
  const withExtra = { ...GOOD, evil: "<script>", colors: { ...GOOD.colors, bonus: "#000000" } };
  const out = parseBrandSpec(JSON.stringify(withExtra));
  assert.ok(out && !("evil" in out));
  assert.deepEqual(Object.keys(out.colors).sort(),
    ["accent", "background", "ink", "secondary", "surface"]);
});

test("parseBrandSpec: an invalid spec (bad font) → null", () => {
  assert.equal(parseBrandSpec(JSON.stringify({ ...GOOD, display_font: "Wingdings" })), null);
});

test("parseBrandSpec: non-JSON and missing colors → null", () => {
  assert.equal(parseBrandSpec("sorry, I couldn't read the references"), null);
  assert.equal(parseBrandSpec(JSON.stringify({ display_font: "Inter" })), null);
  assert.equal(parseBrandSpec(null), null);
});

test("defaultSpec: each preset maps to its tokens; accent passes through", () => {
  const warm = defaultSpec({ accent: "#B85C38", themePreset: "warm" });
  assert.equal(warm.colors.background, "#FAFAF7");
  assert.equal(warm.colors.ink, "#14170E");
  assert.equal(warm.colors.accent, "#B85C38");
  assert.equal(warm.display_font, "Space Grotesk");
  assert.equal(warm.layout, "list");
  assert.equal(defaultSpec({ themePreset: "bold" }).colors.surface, "#16181A");
  assert.equal(defaultSpec({ themePreset: "calm" }).colors.background, "#F2F5F2");
  assert.ok(isValidSpec(defaultSpec({ accent: "#123456" })));
});

test("defaultSpec: a missing/invalid accent falls back to neutral, still valid", () => {
  assert.equal(defaultSpec({ accent: "nope" }).colors.accent, "#78716C");
  assert.equal(defaultSpec({}).colors.accent, "#78716C");
  assert.ok(isValidSpec(defaultSpec({})));
});

test("the font list is exactly the ten vendored families", () => {
  assert.equal(BRAND_FONTS.length, 10);
  assert.ok(BRAND_FONTS.includes("Space Grotesk") && BRAND_FONTS.includes("Fraunces"));
});

// --- Decision 93 slice 3 — optional per-post layout fields ------------------

test("slice 3: an old spec (no layout fields) still validates unchanged", () => {
  assert.equal(isValidSpec(GOOD), true);
  // parseBrandSpec of a layout-free spec carries no optional keys
  const back = parseBrandSpec(JSON.stringify(GOOD));
  assert.ok(back);
  assert.equal("image_placement" in back, false);
  assert.equal("background_image" in back, false);
  assert.equal("size_scale" in back, false);
  assert.equal("element_order" in back, false);
});

test("slice 3: valid optional fields pass; out-of-range are rejected", () => {
  const ok = {
    ...GOOD, background_image: "studio/2027-03/edit-1.jpg", image_placement: "full",
    overlay_strength: 0.4, text_align: "center",
    size_scale: { time: 1.5, name: 0.8 }, element_order: ["title", "classes", "footer", "logo"],
  };
  assert.equal(isValidSpec(ok), true);
  assert.equal(isValidSpec({ ...GOOD, image_placement: "diagonal" }), false);
  assert.equal(isValidSpec({ ...GOOD, text_align: "justify" }), false);
  assert.equal(isValidSpec({ ...GOOD, overlay_strength: 1.5 }), false);
  assert.equal(isValidSpec({ ...GOOD, overlay_strength: -0.1 }), false);
  assert.equal(isValidSpec({ ...GOOD, size_scale: { time: 5 } }), false);      // > 2
  assert.equal(isValidSpec({ ...GOOD, size_scale: { header: 0.1 } }), false);  // < 0.5
  assert.equal(isValidSpec({ ...GOOD, element_order: ["title", "banner"] }), false);
  assert.equal(isValidSpec({ ...GOOD, background_image: 42 }), false);
});

test("slice 3: parseBrandSpec keeps good layout fields and drops unknown keys", () => {
  const txt = JSON.stringify({
    ...GOOD, image_placement: "left", overlay_strength: 0.3, text_align: "right",
    size_scale: { time: 1.2, bogus: 9 }, element_order: ["classes", "nope", "logo"],
    invented_field: "x",
  });
  const s = parseBrandSpec(txt);
  assert.ok(s);
  assert.equal(s.image_placement, "left");
  assert.equal(s.overlay_strength, 0.3);
  assert.deepEqual(s.size_scale, { time: 1.2 });          // bogus key dropped
  assert.deepEqual(s.element_order, ["classes", "logo"]); // "nope" filtered
  assert.equal("invented_field" in s, false);             // unknown key stripped
});
