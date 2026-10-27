// Decision 84 — the pure reset-flow helpers (lib/password-reset.mjs). The live
// Supabase calls (resetPasswordForEmail / updateUser) are NOT node-tested — the
// repo's convention is the same for signUp (lib/auth-redirect.mjs); what is
// testable, and worth locking, is the logic the two request actions and the
// /reset page branch on.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  RESET_SENT, MIN_PASSWORD, requestOutcome, validateNewPassword, resetNext, resetRedirect,
} from "../lib/password-reset.mjs";

test("requestOutcome: the SAME response for an unknown email as a known one", () => {
  // The whole point of Decision 84's "don't reveal existence": the request
  // never consults whether the address has an account, so two different
  // non-blank addresses must yield the byte-identical outcome.
  const known = requestOutcome("alena.fabricated@example.com");
  const unknown = requestOutcome("nobody-at-all@example.com");
  assert.deepEqual(known, { ok: true });
  assert.deepEqual(unknown, { ok: true });
  assert.deepEqual(known, unknown);
});

test("requestOutcome: trims, and an all-whitespace or empty email is the only refusal", () => {
  assert.deepEqual(requestOutcome("  spaced@example.com  "), { ok: true });
  assert.ok("error" in requestOutcome(""));
  assert.ok("error" in requestOutcome("   "));
  assert.ok("error" in requestOutcome(null));
  assert.ok("error" in requestOutcome(undefined));
});

test("validateNewPassword: length floor is the signup policy (8), not Supabase's 6", () => {
  assert.equal(MIN_PASSWORD, 8);
  assert.ok("error" in validateNewPassword("short12", "short12")); // 7 chars
  assert.deepEqual(validateNewPassword("abcd1234", "abcd1234"), { ok: true }); // 8 chars
});

test("validateNewPassword: the two entries must match", () => {
  const r = validateNewPassword("abcd1234", "abcd1235");
  assert.ok("error" in r);
  assert.match(r.error, /do not match/i);
});

test("validateNewPassword: non-string inputs are refused, never accepted", () => {
  assert.ok("error" in validateNewPassword(null, null));
  assert.ok("error" in validateNewPassword(undefined, undefined));
});

test("resetNext: role travels in the one param the shared /reset page reads", () => {
  assert.equal(resetNext("instructor"), "/reset?role=instructor");
  assert.equal(resetNext("member"), "/reset");
  assert.equal(resetNext(undefined), "/reset");
});

test("resetRedirect: each role lands on its own login with an acknowledgement", () => {
  assert.equal(resetRedirect("instructor"), "/instructor/login?reset=1");
  assert.equal(resetRedirect("member"), "/login?reset=1");
  assert.equal(resetRedirect("staff"), "/login?reset=1");
});

test("RESET_SENT is the one fixed success line, mentioning the hour expiry", () => {
  assert.match(RESET_SENT, /expires in an hour/i);
  assert.match(RESET_SENT, /if that email has an account/i);
});
