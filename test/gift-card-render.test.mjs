// The gift card image draws the peso sign (U+20B1), not an empty glyph box.
// next/og's built-in font has no ₱, so the card drew □2,000 on production;
// the route now loads Space Grotesk (GIFT_CARD_FONTS), which carries it.
//
// Rendered through the same next/og ImageResponse the route uses. A character
// the font lacks renders as the font's .notdef box, identical to any other
// missing character (U+E000, a private-use point no font here maps). So:
//   - with the card font, "₱" must NOT render like that missing character;
//   - with the built-in font alone (the old card), it DOES — the bug this fixes.
//     That half is not an automated test: for a glyph its font lacks, next/og
//     tries to download a Google font, which returns 400 for ₱ (as on
//     production), so it would depend on the network. It was checked by hand:
//     with a font lacking ₱ (Bodoni Moda) the ₱ render equals the missing-
//     glyph render byte for byte.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";
import { GIFT_CARD_FONTS, GIFT_CARD_FONT_FAMILY, cardAmountLabel } from "../lib/gift-card.mjs";

const root = process.cwd();
const require = createRequire(import.meta.url);
const fontkit = require("@pdf-lib/fontkit");
const { ImageResponse } = await import(
  join(root, "node_modules/next/dist/compiled/@vercel/og/index.node.js")
);

const PESO = "₱";
const MISSING = "";
const fontBytes = (file) => readFileSync(join(root, "public/fonts/invoice", file));
const cardFonts = GIFT_CARD_FONTS.map((f) => ({
  name: GIFT_CARD_FONT_FAMILY, data: fontBytes(f.file), weight: f.weight, style: "normal",
}));

async function render(text, withCardFont) {
  const el = {
    type: "div",
    props: {
      style: {
        display: "flex", width: 160, height: 160, fontSize: 120, background: "#ffffff", color: "#000000",
        fontFamily: withCardFont ? `"${GIFT_CARD_FONT_FAMILY}"` : "sans-serif", fontWeight: 700,
      },
      children: text,
    },
  };
  const r = new ImageResponse(el, { width: 160, height: 160, ...(withCardFont ? { fonts: cardFonts } : {}) });
  return Buffer.from(await r.arrayBuffer());
}

test("every card font file carries the peso sign", () => {
  for (const f of GIFT_CARD_FONTS) {
    const font = fontkit.create(fontBytes(f.file));
    assert.ok(font.hasGlyphForCodePoint(0x20b1), `${f.file} has no U+20B1`);
    assert.ok(font.glyphForCodePoint(0x20b1).path.commands.length > 0, `${f.file} U+20B1 is empty`);
  }
});

test("with the card font, ₱ is drawn as a real glyph, not the missing-glyph box", async () => {
  const peso = await render(PESO, true);
  const missing = await render(MISSING, true);
  const blank = await render(" ", true);
  assert.notDeepEqual(peso, missing, "₱ rendered as the .notdef box");
  assert.notDeepEqual(peso, blank, "₱ rendered as nothing");
});

test("the amount label keeps ₱ with the font, falls back to the ISO code without it", () => {
  assert.equal(cardAmountLabel("₱2,000", "PHP", true), "₱2,000");
  assert.equal(cardAmountLabel("₱2,000", "PHP", false), "2,000 PHP");
  assert.equal(cardAmountLabel("₱1,250.50", "PHP", false), "1,250.50 PHP");
  assert.ok(!/[₱]/.test(cardAmountLabel("₱2,000", "PHP", false)));
});
