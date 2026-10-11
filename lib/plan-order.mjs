// Decision 74 — plan display order. The one pure rule for ordering plans shown
// to members and staff: FEATURED first, then by sort_order ascending, with
// ARCHIVED (status <> 'active') last whatever their sort_order. Plain ESM so it
// runs under `node --test` (test/plan_order.test.mjs) and in the member page.

/** Sort a copy of `plans` by (archived last, featured first, sort_order asc). */
export function sortPlans(plans) {
  return [...plans].sort((a, b) => {
    const aArch = a.status && a.status !== "active" ? 1 : 0;
    const bArch = b.status && b.status !== "active" ? 1 : 0;
    if (aArch !== bArch) return aArch - bArch;               // archived last
    const aFeat = a.featured ? 0 : 1;
    const bFeat = b.featured ? 0 : 1;
    if (aFeat !== bFeat) return aFeat - bFeat;               // featured first
    return (a.sort_order ?? 0) - (b.sort_order ?? 0);        // then sort_order
  });
}

/** A badge is null/absent or at most 24 characters (mirrors the DB CHECK). */
export function badgeOk(badge) {
  return badge == null || (typeof badge === "string" && badge.length <= 24);
}

/** Trim a badge input, empty -> null, and clamp to the 24-char ceiling so a
 *  write can never be refused by the CHECK on length. */
export function clampBadge(badge) {
  const t = typeof badge === "string" ? badge.trim() : "";
  return t ? t.slice(0, 24) : null;
}
