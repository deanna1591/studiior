import { test } from "node:test";
import assert from "node:assert/strict";
import { normalisePhone, formatPhone, PHONE_INVALID } from "../lib/phone.mjs";

test("PH mobile normalises to E.164", () => {
  assert.equal(normalisePhone("PH", "09171234567"), "+639171234567");
  assert.equal(normalisePhone("PH", "+63 917 123 4567"), "+639171234567");
  assert.equal(normalisePhone("PH", "+639171234567"), "+639171234567");
  assert.equal(normalisePhone("PH", "639171234567"), "+639171234567");
  assert.equal(normalisePhone("ph", "0917 123 4567"), "+639171234567"); // case-insensitive country
});

test("PH rejects what is not a PH mobile", () => {
  assert.equal(normalisePhone("PH", "0917123"), null);        // too short
  assert.equal(normalisePhone("PH", "9171234567"), null);     // no 0 / 63 prefix
  assert.equal(normalisePhone("PH", "081712345678"), null);   // wrong second digit
  assert.equal(normalisePhone("PH", ""), null);
  assert.equal(normalisePhone("PH", null), null);
});

test("a non-PH studio accepts 7 to 15 digits", () => {
  assert.equal(normalisePhone("US", "5551234567"), "5551234567");
  assert.equal(normalisePhone("US", "+1 555 123 4567"), "+15551234567");
  assert.equal(normalisePhone(null, "12345678"), "12345678");   // null country => generic
  assert.equal(normalisePhone("GB", "123456"), null);           // 6 digits, too short
  assert.equal(normalisePhone("GB", "1234567890123456"), null); // 16 digits, too long
  assert.equal(normalisePhone("GB", "1234567"), "1234567");     // exactly 7
  assert.equal(normalisePhone("GB", "123456789012345"), "123456789012345"); // exactly 15
});

test("formatPhone renders a PH number for display", () => {
  assert.equal(formatPhone("+639171234567"), "+63 917 123 4567");
  assert.equal(formatPhone("+15551234567"), "+15551234567"); // non-PH stays as stored
  assert.equal(formatPhone(""), "");
  assert.equal(formatPhone(null), "");
});

test("the invalid copy has no em dash", () => {
  assert.equal(PHONE_INVALID, "That doesn't look like a mobile number.");
  assert.ok(!/—/.test(PHONE_INVALID));
});
