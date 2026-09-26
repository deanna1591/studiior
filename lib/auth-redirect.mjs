// Decision 41. Pure helpers for the per-studio auth callback redirect.
//
// No Next imports on purpose: this runs under `node --test`
// (test/auth_redirect.test.mjs) as well as inside the signUp server action and
// the /auth/callback route — ONE implementation, testable without a bundler.
// (Node 20 here cannot import a .ts, so the shared source is ESM JS with a
// sibling .d.ts for the TypeScript side; moduleResolution "bundler" resolves
// the .mjs at build.)

// A safe post-confirmation destination: a RELATIVE path only. Anything else —
// an absolute URL, a protocol-relative "//host", a "/\" backslash trick, a
// control character, or a non-string — collapses to "/". This is the
// open-redirect guard, used BOTH when building the confirmation link and when
// the callback follows the ?next it was handed (which a member could edit).
export function safeNext(next) {
  if (typeof next !== "string" || next.length === 0) return "/";
  if (next[0] !== "/") return "/";
  if (next.startsWith("//") || next.startsWith("/\\")) return "/";
  if (/[\u0000-\u001f]/.test(next)) return "/";
  return next;
}

// The confirmation / password-reset link Supabase should send the member back
// to: the callback on THIS studio's own member origin, carrying a safe next.
// memberOrigin is the current member host (e.g. https://reform.studiior.app),
// chosen per request — never the project-wide Site URL.
export function buildAuthCallback(memberOrigin, next) {
  return memberOrigin + "/auth/callback?next=" + encodeURIComponent(safeNext(next));
}
