// Decision 41 — unit test for the per-studio auth-redirect builder + guard.
// Runs with zero deps:  node --test test/auth_redirect.test.mjs
// (This project has no JS test runner wired into run-suites.sh, which is SQL;
// this is a standalone Node built-in test of the pure helpers.)
import { test } from "node:test";
import assert from "node:assert/strict";
import { safeNext, buildAuthCallback } from "../lib/auth-redirect.mjs";

test("safeNext keeps a relative path", () => {
  assert.equal(safeNext("/class/abc"), "/class/abc");
  assert.equal(safeNext("/settings"), "/settings");
  assert.equal(safeNext("/"), "/");
});

test("safeNext rejects anything that is not a plain relative path", () => {
  assert.equal(safeNext("https://evil.com"), "/");            // absolute URL
  assert.equal(safeNext("http://reform.studiior.app/x"), "/"); // absolute, even same brand
  assert.equal(safeNext("//evil.com"), "/");                  // protocol-relative
  assert.equal(safeNext("/\\evil.com"), "/");                 // backslash trick
  assert.equal(safeNext("evil.com"), "/");                    // no leading slash
  assert.equal(safeNext("/foo\nbar"), "/");                   // control char
  assert.equal(safeNext(""), "/");
  assert.equal(safeNext(undefined), "/");
  assert.equal(safeNext(null), "/");
  assert.equal(safeNext(123), "/");
});

test("buildAuthCallback points at the member origin's callback with an encoded next", () => {
  assert.equal(
    buildAuthCallback("https://reform.studiior.app", "/class/abc"),
    "https://reform.studiior.app/auth/callback?next=%2Fclass%2Fabc",
  );
  assert.equal(
    buildAuthCallback("http://reform.lvh.me:3000", "/"),
    "http://reform.lvh.me:3000/auth/callback?next=%2F",
  );
});

test("buildAuthCallback rejects an absolute next (open-redirect guard) -> /", () => {
  assert.equal(
    buildAuthCallback("https://reform.studiior.app", "https://evil.com/steal"),
    "https://reform.studiior.app/auth/callback?next=%2F",
  );
  assert.equal(
    buildAuthCallback("https://reform.studiior.app", "//evil.com"),
    "https://reform.studiior.app/auth/callback?next=%2F",
  );
});
