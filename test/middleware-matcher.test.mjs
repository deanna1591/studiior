import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

// Decision 52a — prove the ACTUAL middleware matcher (read from middleware.ts,
// not a copy) excludes /.well-known so those paths bypass the rewrite/session
// refresh, while ordinary member paths still match.
const src = readFileSync(new URL("../middleware.ts", import.meta.url), "utf8");
const m = src.match(/matcher:\s*\[\s*"([^"]+)"\s*\]/);
assert.ok(m, "could not find the matcher string in middleware.ts");
// m[1] is the source-literal (e.g. \\.well-known); JSON.parse turns the string
// escapes into the actual runtime pattern Next compiles (\.well-known).
const pattern = JSON.parse('"' + m[1] + '"');
const re = new RegExp("^" + pattern + "$");

test(".well-known paths are EXCLUDED (bypass middleware)", () => {
  assert.equal(re.test("/.well-known/assetlinks.json"), false);
  assert.equal(re.test("/.well-known/apple-app-site-association"), false);
});
test("ordinary member paths still match (middleware runs)", () => {
  assert.equal(re.test("/"), true);
  assert.equal(re.test("/book"), true);
  assert.equal(re.test("/account/delete"), true);
  assert.equal(re.test("/login"), true);
});
test("api and _next are still excluded (unchanged)", () => {
  assert.equal(re.test("/api/xendit/callback"), false);
  assert.equal(re.test("/_next/static/chunk.js"), false);
});
