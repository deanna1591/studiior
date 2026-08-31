import { formatMoney } from "@/lib/plans";
import { dayMonthParts, fmtTime } from "@/lib/time";

type Ev = {
  id: string;
  type: string;
  occurred_at: string;
  title: string;
  description: string | null;
  metadata: unknown;
};

/**
 * The journey, newest first, grouped by month.
 *
 * A dot and a rule rather than a card each. This is the longest list on the
 * screen — a year of a twice-weekly member is a hundred entries — so the row
 * has to stay cheap to read: when, what, and only then any detail.
 *
 * Only `payment` and `cancelled` get colour, because they are the only two an
 * owner scans for. Colouring every attendance would make a healthy member's
 * timeline a solid block of lime and tell them nothing.
 */
const DOT: Record<string, string> = {
  joined: "var(--lime-text)",
  attended: "var(--line-2)",
  cancelled: "var(--coral)",
  payment: "var(--ink-3)",
  membership_changed: "var(--lime-text)",
};

export function TimelineList({ events, timeZone }: { events: Ev[]; timeZone: string }) {
  const groups: { label: string; items: Ev[] }[] = [];
  for (const e of events) {
    const label = new Intl.DateTimeFormat("en-GB", {
      timeZone, month: "long", year: "numeric",
    }).format(new Date(e.occurred_at));
    const last = groups[groups.length - 1];
    if (last && last.label === label) last.items.push(e);
    else groups.push({ label, items: [e] });
  }

  return (
    <div className="space-y-5">
      {groups.map((g) => (
        <div key={g.label}>
          <h3 className="mb-1.5 text-[11px] uppercase leading-4 tracking-[0.06em] text-ink-3">
            {g.label}
          </h3>
          <ul className="space-y-0">
            {g.items.map((e) => {
              const { day, month } = dayMonthParts(e.occurred_at, timeZone);
              const meta = (e.metadata ?? {}) as { amount_cents?: number; currency?: string };
              return (
                <li key={e.id} className="flex gap-3 border-b border-line py-1.5 last:border-0">
                  <span className="num w-[52px] shrink-0 pt-px text-[12px] text-ink-3">
                    {day} <span className="font-sans">{month}</span>
                  </span>
                  <span
                    className="mt-[7px] h-1.5 w-1.5 shrink-0 rounded-full"
                    style={{ background: DOT[e.type] ?? "var(--line-2)" }}
                    aria-hidden
                  />
                  <span className="min-w-0 flex-1">
                    <span className="block text-[13px] leading-[18px] text-ink">
                      {e.title}
                      {e.type === "attended" && (
                        <span className="ml-1.5 num text-[11px] text-ink-3">
                          {fmtTime(e.occurred_at, timeZone)}
                        </span>
                      )}
                    </span>
                    {e.description && (
                      <span className="block text-[11px] leading-4 text-ink-3">{e.description}</span>
                    )}
                  </span>
                  {meta.amount_cents != null && meta.currency && (
                    <span className="num shrink-0 pt-px text-[12px] text-ink-2">
                      {formatMoney(meta.amount_cents, meta.currency)}
                    </span>
                  )}
                </li>
              );
            })}
          </ul>
        </div>
      ))}
    </div>
  );
}
