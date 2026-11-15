// Decision 105: last visit as a relative day. Today, Yesterday, N days ago, N
// weeks ago, else the date. Pure and node-tested; the studio timezone decides
// which calendar day an instant falls on.
export function relativeDay(iso, timeZone, now = new Date()) {
  if (!iso) return null;
  const key = (d) => new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
  const dayNo = (d) => { const [y, m, dd] = key(d).split("-").map(Number); return Math.floor(Date.UTC(y, m - 1, dd) / 86400000); };
  const then = dayNo(new Date(iso));
  const today = dayNo(now);
  const diff = today - then;
  if (diff <= 0) return "Today";
  if (diff === 1) return "Yesterday";
  if (diff < 7) return `${diff} days ago`;
  if (diff < 14) return "1 week ago";
  if (diff < 56) return `${Math.floor(diff / 7)} weeks ago`;
  // older than ~8 weeks: the date itself, in the studio zone
  return new Intl.DateTimeFormat("en-GB", { timeZone, day: "numeric", month: "short", year: dayNo(new Date(iso)) < today - 300 ? "numeric" : undefined }).format(new Date(iso));
}
