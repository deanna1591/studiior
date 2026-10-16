// Decision 55 follow-up — pure helpers for the free-class view on the Book tab.
// The button and the rule must never contradict each other: "Book free" shows
// only where a free booking actually works. Node-tested, no RPC.

// The occurrence ids where a free booking actually succeeds (present in
// free_first_class_list AND still free-bookable — a full-for-free class is in
// the list but pays, so it is NOT here). This drives "Book free" on the
// timetable; every other row gets the paid Book button + the muted note.
export function freeEligibleSet(freeList = []) {
  return new Set((freeList || []).filter((c) => c && c.free_bookable).map((c) => c.occurrence_id));
}

// Which view the Book tab opens with: the picker (primary) when the member is
// eligible, has at least one eligible class, and has not asked for the full
// timetable (?all=1); otherwise the regular timetable.
export function whichView({ freeFirstEligible = false, eligibleCount = 0, showAll = false } = {}) {
  return freeFirstEligible && eligibleCount > 0 && !showAll ? "picker" : "timetable";
}

// The studio-local day key the picker opens on for a ?d= deep link: that day if
// it has an eligible class, else the nearest day that does (tie → the earlier).
// dayKeys are the eligible classes' studio-local YYYY-MM-DD keys.
export function nearestEligibleDay(dayKeys = [], wanted = null) {
  const keys = [...new Set((dayKeys || []).filter(Boolean))].sort();
  if (keys.length === 0) return null;
  if (!wanted || !/^\d{4}-\d{2}-\d{2}$/.test(wanted)) return keys[0];
  if (keys.includes(wanted)) return wanted;
  const wd = Date.parse(`${wanted}T00:00:00Z`);
  let best = keys[0], bestDist = Infinity;
  for (const k of keys) {
    const dist = Math.abs(Date.parse(`${k}T00:00:00Z`) - wd);
    if (dist < bestDist) { bestDist = dist; best = k; }
  }
  return best;
}
