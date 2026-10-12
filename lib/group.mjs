// Decision 76b — pure helpers for the member group-booking flow. No imports, so
// `node --test` (test/group.test.mjs) runs them with no bundler. Two things:
//   - validateGroupEmails: the client-side check on the emails screen (count,
//     non-empty, distinct, not the host). "Already booked on that class" is a
//     server fact — book_group raises it by name — so it is NOT checked here.
//   - eligibleGroupClasses: the "pick your class" filter — a future, scheduled
//     class with at least group_size free seats. The book-by date is shown by
//     the page; this filter is only about seats and time.

/** lower(trim(email)); "" for null/blank. */
function norm(e) {
  return typeof e === "string" ? e.trim().toLowerCase() : "";
}

/**
 * Validate the group_size − 1 guest emails against the host. Returns the first
 * problem as { index, reason, email } or { ok: true }.
 *
 * reasons: 'wrong_count' | 'blank' | 'duplicate' | 'is_host'.
 *
 * @param {string[]} emails           the guest emails (expected group_size − 1)
 * @param {string} hostEmail          the host's own email (seat one)
 * @param {number} groupSize          the plan's group size
 */
export function validateGroupEmails(emails, hostEmail, groupSize) {
  const list = Array.isArray(emails) ? emails : [];
  if (list.length !== groupSize - 1) {
    return { ok: false, reason: "wrong_count", expected: groupSize - 1, got: list.length };
  }
  const host = norm(hostEmail);
  const seen = new Set();
  for (let i = 0; i < list.length; i++) {
    const e = norm(list[i]);
    if (e === "") return { ok: false, reason: "blank", index: i };
    if (e === host) return { ok: false, reason: "is_host", index: i, email: list[i] };
    if (seen.has(e)) return { ok: false, reason: "duplicate", index: i, email: list[i] };
    seen.add(e);
  }
  return { ok: true };
}

/**
 * The classes a group of group_size can be booked into: scheduled, in the
 * future, with at least group_size free seats. Free = capacity − booked_count −
 * held (held optional, defaults 0 — book_group re-checks held under the lock).
 *
 * @param {Array<{occurrence_id?:string,id?:string,starts_at:string,status?:string,capacity:number,booked_count:number,seats_held?:number}>} classes
 * @param {number} groupSize
 * @param {number} nowMs   Date.now() (so the filter is testable at a fixed time)
 * @returns the same objects, future-first, that have room for the whole group.
 */
export function eligibleGroupClasses(classes, groupSize, nowMs) {
  const list = Array.isArray(classes) ? classes : [];
  return list
    .filter((c) => {
      if (c.status && c.status !== "scheduled") return false;
      if (new Date(c.starts_at).getTime() <= nowMs) return false;
      const free = (c.capacity ?? 0) - (c.booked_count ?? 0) - (c.seats_held ?? 0);
      return free >= groupSize;
    })
    .sort((a, b) => new Date(a.starts_at).getTime() - new Date(b.starts_at).getTime());
}
