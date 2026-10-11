// Decision 57 — the website buy-link builders (lib/member-urls.mjs) and the
// shared `next` validator (lib/auth-redirect.mjs safeNext, which the buy page's
// Sign in / Create account links are validated through). Zero deps:
//   node --test test/member_urls.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { buyPath, buyUrl, payNowHref } from "../lib/member-urls.mjs";
import { safeNext } from "../lib/auth-redirect.mjs";

test("buyPath is /buy/{plan}", () => {
  assert.equal(buyPath("abc"), "/buy/abc");
  assert.equal(buyPath("11111111-0000-0000-0000-0000000000c1"), "/buy/11111111-0000-0000-0000-0000000000c1");
});

test("buyUrl joins the member origin and the path, tolerating a trailing slash", () => {
  assert.equal(buyUrl("https://reform.studiior.app", "p1"), "https://reform.studiior.app/buy/p1");
  assert.equal(buyUrl("https://reform.studiior.app/", "p1"), "https://reform.studiior.app/buy/p1");
  assert.equal(buyUrl("http://reform.lvh.me:3000", "p1"), "http://reform.lvh.me:3000/buy/p1");
});

test("the buy ?next is a relative path and is open-redirect guarded", () => {
  assert.equal(safeNext("/buy/abc"), "/buy/abc");                 // the real case
  assert.equal(safeNext("//evil.com"), "/");                       // protocol-relative rejected
  assert.equal(safeNext("https://evil.com/buy/x"), "/");           // absolute rejected
  assert.equal(safeNext(undefined), "/");                          // missing -> "/"
  assert.equal(safeNext(""), "/");                                 // empty -> "/"
});

test("payNowHref targets the plans page with a relative ?return, open-redirect guarded (Decision 73b)", () => {
  assert.equal(payNowHref("/class/abc"), "/account/plan?return=%2Fclass%2Fabc");  // the real case
  assert.equal(payNowHref(null), "/account/plan");                                 // no return
  assert.equal(payNowHref(undefined), "/account/plan");
  assert.equal(payNowHref("//evil.com"), "/account/plan");                         // protocol-relative dropped
  assert.equal(payNowHref("https://evil.com"), "/account/plan");                   // absolute dropped
  assert.equal(payNowHref("/\\evil"), "/account/plan");                            // backslash trick dropped
});
