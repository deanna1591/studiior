import { dayMonthParts } from "@/lib/time";

/**
 * Attendance as a shape, not a list.
 *
 * The journey below already names every visit, so repeating them here would be
 * the same information twice with the second copy stripped of context. What is
 * missing from a list is the pattern — and the pattern is exactly what the
 * health band is claiming when it says "was coming about every 4 days". Twelve
 * months of counts lets someone check that claim in one look.
 */
export function AttendancePattern({
  visits, timeZone, months = 12,
}: {
  visits: { checked_in_at: string }[];
  timeZone: string;
  months?: number;
}) {
  const key = (d: Date) =>
    new Intl.DateTimeFormat("en-GB", { timeZone, month: "short", year: "2-digit" }).format(d);

  // Build the buckets first so a month with no visits is a gap, not a missing
  // column — an absent month is the whole point of looking.
  const now = new Date();
  const buckets: { label: string; n: number }[] = [];
  for (let i = months - 1; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    buckets.push({ label: key(d), n: 0 });
  }
  const index = new Map(buckets.map((b, i) => [b.label, i]));
  for (const v of visits) {
    const i = index.get(key(new Date(v.checked_in_at)));
    if (i !== undefined) buckets[i].n += 1;
  }

  const peak = Math.max(1, ...buckets.map((b) => b.n));

  return (
    <div>
      <div className="flex items-end gap-[3px]" style={{ height: 56 }}>
        {buckets.map((b, i) => (
          <div key={i} className="flex flex-1 flex-col items-center justify-end gap-1" title={`${b.label}: ${b.n}`}>
            <span className="num text-[10px] leading-none text-ink-3">{b.n || ""}</span>
            <div
              className={b.n === 0 ? "w-full bg-line" : "w-full bg-lime"}
              style={{ height: b.n === 0 ? 2 : Math.max(4, Math.round((b.n / peak) * 40)) }}
            />
          </div>
        ))}
      </div>
      <div className="mt-1 flex gap-[3px] text-[10px] leading-4 text-ink-3">
        {buckets.map((b, i) => (
          <span key={i} className="flex-1 text-center">
            {/* Only the January-ish marks, or twelve labels turn to mush. */}
            {i === 0 || b.label.startsWith("Jan") ? b.label.split(" ")[0] : ""}
          </span>
        ))}
      </div>
    </div>
  );
}

export function lastVisitLine(
  iso: string | null, timeZone: string,
): React.ReactNode {
  if (!iso) return null;
  const { day, month } = dayMonthParts(iso, timeZone);
  return <><span className="num">{day}</span> {month}</>;
}
