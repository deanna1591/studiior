import Link from "next/link";
import { formatMoney } from "@/lib/plans";
import { rowLine, statementTitle } from "@/lib/statement";
import { dayMonthParts, type TimeFormat } from "@/lib/time";

/** A member_activity row carried through from the profile page. */
type Ev = {
  id: string;
  kind: string;
  at: string;
  title: string;
  detail: string | null;
  credit_delta: number | null;
  balance_after: number | null;
  amount_cents: number | null;
  currency: string | null;
  occurrence_id: string | null;
  booking_id: string | null;
  membership_id: string | null;
  plan_name: string | null;
  due_cents: number | null;
  is_free_first: boolean | null;
  occurrence_start: string | null;
  instructor_first: string | null;
  credits_left_after: number | null;
  payment_method: string | null;
  recorded_by_name: string | null;
  plan_classes: number | null;
  plan_valid_to: string | null;
  unused_credits: number | null;
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
 *
 * Decision 83: the row is a LINK (never a button — nothing acts from the
 * journey). A class row opens that class's roster, scrolled to this member;
 * a money row jumps to the membership (or, for a manager, the payments) panel
 * on this same page. The title (statementTitle) and the second line (rowLine)
 * are the same shared helper the member sees in /history, with forStaff so a
 * desk payment also names who recorded it; a running balance rides credit rows.
 */
const DOT: Record<string, string> = {
  joined: "var(--lime-text)",
  attended: "var(--line-2)",
  booked: "var(--line-2)",
  waitlisted: "var(--line-2)",
  free_first: "var(--lime-text)",
  cancelled: "var(--coral)",
  late_cancelled: "var(--coral)",
  studio_cancelled: "var(--coral)",
  no_show: "var(--coral)",
  rescheduled: "var(--amber-deep)",
  instructor_changed: "var(--amber-deep)",
  payment: "var(--ink-3)",
  purchase: "var(--ink-3)",
  refund: "var(--ink-3)",
  payment_failed: "var(--coral)",
  credits_added: "var(--lime-text)",
  credit_used: "var(--line-2)",
  credit_adjustment: "var(--ink-3)",
  membership_changed: "var(--lime-text)",
  message_sent: "var(--ink-3)",
};

const PAYMENT_KINDS = new Set(["purchase", "refund", "payment_failed"]);

export function TimelineList({ events, timeZone, timeFormat = "24h", memberId, manager, currency }:
  { events: Ev[]; timeZone: string; timeFormat?: TimeFormat; memberId: string; manager: boolean; currency: string }) {
  const money = (c: number) => formatMoney(c, currency);

  function href(e: Ev): string | null {
    if (e.occurrence_id) return `/roster/${e.occurrence_id}?member=${memberId}`;
    if (PAYMENT_KINDS.has(e.kind)) return manager ? "#payments" : "#membership";
    if (e.membership_id || (e.credit_delta ?? 0) !== 0) return "#membership";
    return null;
  }

  const groups: { label: string; items: Ev[] }[] = [];
  for (const e of events) {
    const label = new Intl.DateTimeFormat("en-GB", {
      timeZone, month: "long", year: "numeric",
    }).format(new Date(e.at));
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
              const { day, month } = dayMonthParts(e.at, timeZone);
              const cd = e.credit_delta ?? 0;
              // The left column already carries the event date, so rowLine owns
              // the second line alone (forStaff: desk payments name the recorder).
              const second = rowLine(e, money, { tz: timeZone, timeFormat }, true);
              const to = href(e);
              const body = (
                <>
                  <span className="num w-[52px] shrink-0 pt-px text-[12px] text-ink-3">
                    {day} <span className="font-sans">{month}</span>
                  </span>
                  <span
                    className="mt-[7px] h-1.5 w-1.5 shrink-0 rounded-full"
                    style={{ background: DOT[e.kind] ?? "var(--line-2)" }}
                    aria-hidden
                  />
                  <span className="min-w-0 flex-1">
                    <span className="block text-[13px] leading-[18px] text-ink">
                      {statementTitle(e)}
                    </span>
                    {second && (
                      <span className="block text-[11px] leading-4 text-ink-3">{second}</span>
                    )}
                  </span>
                  <span className="shrink-0 pt-px text-right">
                    {e.amount_cents != null && e.currency && (
                      <span className="num block text-[12px] text-ink-2">
                        {formatMoney(e.amount_cents, e.currency)}
                      </span>
                    )}
                    {(cd !== 0 || e.amount_cents != null) && e.balance_after != null && (
                      <span className="num block text-[11px] leading-4 text-ink-3">
                        Balance {e.balance_after}
                      </span>
                    )}
                  </span>
                </>
              );
              return (
                <li key={e.id} className="border-b border-line last:border-0">
                  {to ? (
                    <Link href={to} className="-mx-2 flex gap-3 rounded-lg px-2 py-1.5 transition-colors hover:bg-paper">{body}</Link>
                  ) : (
                    <div className="flex gap-3 py-1.5">{body}</div>
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
