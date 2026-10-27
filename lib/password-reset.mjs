// Decision 84 — pure helpers for the password-reset flow.
//
// No Next imports on purpose (the lib/auth-redirect.mjs pattern): this runs
// under `node --test` (test/password_reset.test.mjs) as well as inside the
// member and staff server actions — ONE implementation, testable without a
// bundler. A sibling .d.ts types the TypeScript side; moduleResolution
// "bundler" resolves the .mjs at build.

// The ONE success line, shown after a reset request on every host and role.
// It never says whether the address has an account — the request returns the
// same response whether or not it does (Decision 84), so this is all the
// member is ever told.
export const RESET_SENT =
  "If that email has an account, a reset link is on its way. It expires in an hour.";

// The minimum new-password length. Matches signUp()'s existing policy (8), not
// Supabase's weaker config floor (6) — the stricter of the two is the one a
// member already meets when they signed up.
export const MIN_PASSWORD = 8;

// The outcome of a reset REQUEST, decided without ever consulting whether the
// email exists. A blank email is the only refusal; any non-blank email yields
// the identical {ok} — that sameness IS the "don't reveal existence" property,
// and the node test locks it by comparing two different non-blank addresses.
export function requestOutcome(email) {
  const e = typeof email === "string" ? email.trim() : "";
  if (!e) return { error: "We need an email address." };
  return { ok: true };
}

// New-password validation for the /reset page: long enough, and typed the same
// twice. Returns {ok} or {error} with a reason in the member's words.
export function validateNewPassword(password, confirm) {
  const p = typeof password === "string" ? password : "";
  const c = typeof confirm === "string" ? confirm : "";
  if (p.length < MIN_PASSWORD) return { error: `Pick a password of at least ${MIN_PASSWORD} characters.` };
  if (p !== c) return { error: "The two passwords do not match." };
  return { ok: true };
}

// Where a reset link should return the member — the /reset page on their own
// host, carrying the role so the page can send them to the right login after.
// Member and instructor share the member host; only the post-reset login URL
// differs, so the role travels in this one param.
export function resetNext(role) {
  return role === "instructor" ? "/reset?role=instructor" : "/reset";
}

// The login a finished reset lands on, by role. `?reset=1` lets the login show
// a one-line acknowledgement.
export function resetRedirect(role) {
  if (role === "instructor") return "/instructor/login?reset=1";
  if (role === "staff") return "/login?reset=1";
  return "/login?reset=1";
}
