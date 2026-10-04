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
