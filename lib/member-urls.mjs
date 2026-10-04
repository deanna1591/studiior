// Decision 57 — website buy links. Pure path/url builders, no Next imports, so
// they run under `node --test` (test/member_urls.test.mjs) and in both the
// staff page (building the link to copy) and the member pages (the ?next). The
// member ORIGIN itself comes from memberOrigin(slug) in lib/tenant.ts, which
// needs next/headers env and so is not node-testable; these are the parts worth
// testing — the path shape and the join.

/** The member-host path a studio's "Buy" button points at: /buy/{plan_id}. */
export function buyPath(planId) {
  return "/buy/" + planId;
}

/** The full website buy link: {memberOrigin}/buy/{plan_id}. The origin is
 *  https://{slug}.{member_app_domain} (memberOrigin(slug)); a trailing slash on
 *  it is tolerated so the join never doubles up. */
export function buyUrl(memberOrigin, planId) {
  return String(memberOrigin).replace(/\/+$/, "") + buyPath(planId);
}

const clean = (v) => (typeof v === "string" && v.trim() ? v.trim() : null);

const isLocalHost = (host) => {
  const h = (host || "").split(":")[0].toLowerCase();
  return h === "localhost" || h === "127.0.0.1" || h === "lvh.me"
      || h.endsWith(".localhost") || h.endsWith(".lvh.me");
};

/**
 * Decision 57 follow-up — the member-app base domain for a STAFF-side link,
 * resolved so it never depends on a Vercel env var the staff deployment may not
 * have. In order:
 *   (a) dbValue — notification_config 'member_app_domain' (the source of truth
 *       the SQL email-link helpers use), e.g. "studiior.app";
 *   (b) envValue — process.env.NEXT_PUBLIC_MEMBER_DOMAIN;
 *   (c) when the request host is a NON-local production host, the known
 *       production member domain ("studiior.app") — NEVER localhost on a
 *       non-localhost request;
 *   (d) "localhost:3000" for local dev.
 */
export function resolveMemberBase(dbValue, envValue, requestHost) {
  const db = clean(dbValue);
  if (db) return db;                                   // (a)
  const env = clean(envValue);
  if (env) return env;                                 // (b)
  const host = clean(requestHost);                     // (c)
  if (host && !isLocalHost(host)) return "studiior.app";
  return "localhost:3000";                             // (d)
}

/** {scheme}://{slug}.{base}, http only for a local base. */
export function memberOriginFrom(base, slug) {
  const scheme = isLocalHost(base) ? "http" : "https";
  return `${scheme}://${slug}.${String(base).replace(/\/+$/, "")}`;
}
