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
