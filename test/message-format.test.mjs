import { test } from "node:test";
import assert from "node:assert/strict";
import { normaliseMessage, messageParagraphsHtml } from "../lib/message-format.mjs";

test("Windows line endings are normalised and long gaps collapse", () => {
  assert.equal(normaliseMessage("Hi,\r\n\r\n\r\nLine two\r\nLine three"), "Hi,\n\nLine two\nLine three");
  assert.equal(normaliseMessage("a\rb"), "a\nb");
});

test("a blank line is a paragraph, a single break a <br>", () => {
  assert.equal(messageParagraphsHtml("Hi Ana,\r\n\r\n\r\nSee you <b>tomorrow</b>.\r\nBring socks."),
    '<p style="margin:0 0 10px">Hi Ana,</p><p style="margin:0 0 10px">See you &lt;b&gt;tomorrow&lt;/b&gt;.<br>Bring socks.</p>');
});

test("matches the SQL helper's escaping and ignores empty paragraphs", () => {
  assert.equal(messageParagraphsHtml("\n\nA & B\n\n\n"), '<p style="margin:0 0 10px">A &amp; B</p>');
  assert.equal(messageParagraphsHtml(""), "");
});
