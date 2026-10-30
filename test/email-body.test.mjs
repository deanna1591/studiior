// Decision 77 — the one email-body renderer. Zero deps:
//   node --test test/email-body.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { renderBody } from "../lib/email-body.mjs";

// Collapse whitespace between tags, so "identical rendering" is about structure
// not the newlines between blocks.
const norm = (s) => s.replace(/>\s+</g, "><").trim();

// The renderer today (SQL, 20260832170000): paragraphs on blank lines, & escaped.
const sqlLike = (body) => "<p>" + body.replace(/&/g, "&amp;").replace(/\n\n/g, "</p><p>") + "</p>";

test("paragraphs: a blank line starts a new <p>", () => {
  const { html, text } = renderBody("First para.\n\nSecond para.");
  assert.equal(norm(html), "<p>First para.</p><p>Second para.</p>");
  assert.equal(text, "First para.\n\nSecond para.");
});

test("a single newline inside a paragraph becomes <br>", () => {
  const { html } = renderBody("line one\nline two");
  assert.equal(norm(html), "<p>line one<br>line two</p>");
});

test("**bold** → <strong>", () => {
  const { html, text } = renderBody("a **bold** word");
  assert.equal(norm(html), "<p>a <strong>bold</strong> word</p>");
  assert.equal(text, "a bold word");
});

test("[text](https://url) → an anchor; the text output keeps the words", () => {
  const { html, text } = renderBody("see [our site](https://x.com/book) now");
  assert.equal(norm(html), '<p>see <a href="https://x.com/book">our site</a> now</p>');
  assert.equal(text, "see our site now");
});

test("a non-http link is NOT a link — the literal source is kept (escaped)", () => {
  const { html, text } = renderBody("[bad](javascript:alert(1))");
  assert.equal(norm(html), "<p>[bad](javascript:alert(1))</p>");
  assert.equal(text, "[bad](javascript:alert(1))");
  assert.ok(!/<a /.test(html));
});

test("task 8: an inline link whose URL is a {token} keeps the token in the href", () => {
  const { html, text } = renderBody("See [Manage this booking]({manage_link}) to change it.");
  assert.equal(norm(html),
    '<p>See <a href="{manage_link}">Manage this booking</a> to change it.</p>');
  assert.equal(text, "See Manage this booking to change it.");
});

test("task 8: a non-token, non-http inline URL still falls through to literal text", () => {
  const { html } = renderBody("[bad]({not a token})");
  assert.ok(!/<a /.test(html));
  assert.match(norm(html), /<p>\[bad\]\(\{not a token\}\)<\/p>/);
});

test("![alt](url) on its own line → a full-width img; text becomes [alt]", () => {
  const { html, text } = renderBody("before\n\n![our studio](https://cdn.example.com/a.jpg)\n\nafter");
  assert.match(html, /<img src="https:\/\/cdn\.example\.com\/a\.jpg" alt="our studio"[^>]*width:100%/);
  assert.equal(text, "before\n\n[our studio]\n\nafter");
});

test("an image line with an unsafe URL is not an img — falls back to text", () => {
  const { html } = renderBody("![x](ftp://evil/a.jpg)");
  assert.ok(!/<img/.test(html));
  assert.match(norm(html), /<p>!\[x\]\(ftp:\/\/evil\/a\.jpg\)<\/p>/);
});

test("escaping: raw HTML in the body can never become a tag", () => {
  const { html } = renderBody("<script>alert('x')</script> & <b>no</b>");
  assert.ok(!/<script>/.test(html));
  assert.ok(!/<b>/.test(html));
  assert.match(html, /&lt;script&gt;/);
  assert.match(html, /&amp;/);
});

test("nesting: bold inside a link label", () => {
  const { html } = renderBody("[**go** now](https://x.com)");
  assert.equal(norm(html), '<p><a href="https://x.com"><strong>go</strong> now</a></p>');
});

test("existing plain-paragraph bodies render identically to today's SQL split", () => {
  for (const body of [
    "Hello everyone.\n\nWe have news.\n\nSee you soon.",
    "One line only.",
    "Two paragraphs\n\nwith plain text and nothing special.",
  ]) {
    assert.equal(norm(renderBody(body).html), norm(sqlLike(body)),
      `plain body should match the old split: ${JSON.stringify(body)}`);
  }
});

test("multiple images are allowed, each full width", () => {
  const { html } = renderBody("![a](https://x.com/1.png)\n\n![b](https://x.com/2.png)");
  assert.equal((html.match(/<img /g) ?? []).length, 2);
});

// --- Decision 80a blocks ------------------------------------------------------

test("button: [Label](url){button} → a table button in the accent, with the paired text colour", () => {
  const { html, text } = renderBody("[Book now](https://x.com/book){button}", { accent: "#BEF738" });
  assert.match(html, /<table role="presentation"/);
  assert.match(html, /background:#BEF738/);
  assert.match(html, /color:#14170E/); // lime is light → dark ink paired here
  assert.match(html, /href="https:\/\/x\.com\/book"/);
  assert.match(html, />Book now<\/a>/);
  assert.equal(text, "Book now: https://x.com/book");
});

test("button: a dark accent pairs white text; default accent is neutral grey", () => {
  assert.match(renderBody("[x](https://x.com){button}", { accent: "#1A2B4C" }).html, /color:#FFFFFF/);
  assert.match(renderBody("[x](https://x.com){button}").html, /background:#78716C/);
});

test("button: the {accent} token survives for a static SQL template (both colours tokenised)", () => {
  const { html } = renderBody("[Buy](https://x.com){button}", { accent: "{accent}" });
  assert.match(html, /background:\{accent\}/);
  assert.match(html, /color:\{accent_on\}/);
});

test("button: a {placeholder} url IS a button; an inline {token} link is now an anchor too (task 8)", () => {
  const { html } = renderBody("[Buy]({buy_url}){button}\n\nsee [x]({buy_url}) too", { accent: "{accent}" });
  assert.match(html, /href="\{buy_url\}"[^>]*>Buy<\/a>/); // the button keeps the token
  assert.match(html, /<p>see <a href="\{buy_url\}">x<\/a> too<\/p>/); // the inline link keeps the token in the href
});

test("button: an unsafe url is not a button", () => {
  const { html } = renderBody("[x](javascript:1){button}");
  assert.ok(!/<table/.test(html));
  assert.match(norm(html), /<p>\[x\]\(javascript:1\)\{button\}<\/p>/);
});

test("card: ::: card with name/detail/price/button → a bordered card + button", () => {
  const body = "::: card\nname: 8 Classes Monthly\ndetail: 8 classes · one month\nprice: PHP 1,799\nbutton: Buy it | https://x.com/buy\n:::";
  const { html, text } = renderBody(body, { accent: "#B85C38" });
  assert.match(html, /border:1px solid #E7E5E4/);
  assert.match(html, />8 Classes Monthly<\/div>/);
  assert.match(html, />8 classes · one month<\/div>/);
  assert.match(html, />PHP 1,799<\/div>/);
  assert.match(html, /href="https:\/\/x\.com\/buy"/);
  assert.equal(text, "8 Classes Monthly\n8 classes · one month\nPHP 1,799\nBuy it: https://x.com/buy");
});

test("card: ::: plan <id> resolves through a caller resolver", () => {
  const resolve = (kind, id) =>
    kind === "plan" && id === "p1"
      ? { name: "Intro Offer", detail: "3 classes", price: "PHP 1,799", button: { label: "Book", url: "https://x.com/b" } }
      : null;
  const { html, text } = renderBody("::: plan p1", { resolve });
  assert.match(html, />Intro Offer<\/div>/);
  assert.match(html, /href="https:\/\/x\.com\/b"/);
  assert.match(text, /^Intro Offer\n3 classes\nPHP 1,799\nBook: https:\/\/x\.com\/b$/);
});

test("card: ::: plan <id> with NO resolver degrades to the literal text (never broken)", () => {
  const { html } = renderBody("::: plan p1");
  assert.ok(!/<table/.test(html));
  assert.match(norm(html), /<p>::: plan p1<\/p>/);
});

test("quote: > text — name → an indented quote with the attribution", () => {
  const { html, text } = renderBody("> It changed my week — Maya");
  assert.match(html, /border-left:3px solid #E7E5E4/);
  assert.match(html, /font-style:italic/);
  assert.match(html, />It changed my week<\/div>/);
  assert.match(html, />— Maya<\/div>/);
  assert.equal(text, "It changed my week — Maya");
});

test("divider: --- → a 1px rule, no plain-text line", () => {
  const { html, text } = renderBody("before\n\n---\n\nafter");
  assert.match(html, /border-top:1px solid #E7E5E4/);
  assert.equal(text, "before\n\nafter");
});
