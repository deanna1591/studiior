import { money } from "@/lib/dashboard";
import { classLineText, statusChip, settleWording, disputeMailto } from "@/lib/pay-statement";

// Decision 75b-2 (i) — the ONE statement view, rendered from a pay_statement
// jsonb. Used by the instructor My Pay page and the staff per-instructor
// statement (same component, same RPC). No client JS: the dispute link is a
// plain mailto. Styled with the shared tokens so it reads in either shell.

type Line = {
  type: string; date: string; time: string | null; name: string;
  status: string | null; booked: number | null; checked_in: number | null;
  finalised: boolean | null; headcount_note: string | null;
  from_previous_period: boolean; first_class_on: string | null;
  amount_cents: number; confirmed: boolean; payable: boolean; note: string | null;
};
export type Statement = {
  ok: boolean; instructor_name: string | null; period_id: string;
  starts_on: string; ends_on: string; status: string; currency: string;
  settle_on: string | null; paid_on: string | null; paid_method: string | null; paid_reference: string | null;
  lines: Line[]; total_cents: number; confirmed_cents: number; held_cents: number; held_count: number;
};

const dmy = (iso: string) =>
  new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", day: "numeric", month: "short" })
    .format(new Date(`${iso}T00:00:00Z`));

export default function PayStatementView({ s, contactEmail }: { s: Statement; contactEmail: string | null }) {
  const chip = statusChip(s.status);
  const periodLabel = `${dmy(s.starts_on)} – ${dmy(s.ends_on)}`;
  const settle = settleWording({
    status: s.status,
    settleOn: s.settle_on ? dmy(s.settle_on) : null,
    paidOn: s.paid_on ? dmy(s.paid_on) : null,
    method: s.paid_method,
  });
  const chipStyle =
    chip.tone === "paid" ? { background: "var(--accent-chip)", color: "var(--ink)" }
    : chip.tone === "closed" ? { background: "var(--line)", color: "var(--ink-2)" }
    : { background: "var(--amber-tint)", color: "var(--ink)" };

  return (
    <div>
      <div className="flex items-baseline justify-between gap-3">
        <p className="text-[13px] text-ink-2">{periodLabel}</p>
        <span className="rounded-full px-2.5 py-1 text-[11px] font-semibold leading-4" style={chipStyle}>{chip.label}</span>
      </div>
      <p className="num mt-1 text-[22px] font-semibold leading-7 text-ink">{money(s.total_cents, s.currency)}</p>
      {settle && <p className="mt-1 text-[12px] text-ink-2">{settle}</p>}
      {s.held_count > 0 && (
        <p className="mt-1 text-[12px] text-ink-2">
          {money(s.held_cents, s.currency)} held until {s.held_count === 1 ? "a class is" : "classes are"} checked in.
        </p>
      )}

      <ul className="mt-3 divide-y divide-line">
        {s.lines.map((l, i) => {
          const detail =
            l.type === "class" && l.status === "ran"
              ? classLineText({ booked: l.booked ?? 0, checkedIn: l.checked_in, finalised: !!l.finalised })
              : l.type === "class"
              ? (l.status ?? "")                                   // did not run / cancelled — N
              : l.type === "conversion"
              ? `Conversion bonus${l.first_class_on ? ` · first class ${dmy(l.first_class_on)}` : ""}`
              : (l.note ?? "Adjustment");
          const mailto = disputeMailto({
            email: contactEmail, periodLabel, lineName: l.name,
            lineWhen: `${l.date}${l.time ? " " + l.time : ""}`, amount: money(l.amount_cents, s.currency),
          });
          return (
            <li key={i} className="py-2.5">
              <div className="flex items-baseline justify-between gap-3">
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-[14px] leading-5 text-ink">{l.name}</span>
                  <span className="block text-[12px] leading-4 text-ink-3">
                    {l.date}{l.time ? ` · ${l.time}` : ""} · {detail}
                    {l.from_previous_period && <> · <span className="text-ink-2">from the previous period</span></>}
                  </span>
                  {l.headcount_note && <span className="block text-[11px] leading-4 text-ink-3">{l.headcount_note}</span>}
                </span>
                <span className="shrink-0 text-right">
                  <span className="num block text-[14px] font-semibold leading-5 text-ink">{money(l.amount_cents, s.currency)}</span>
                  {l.type === "class" && !l.confirmed && <span className="block text-[11px] text-ink-2">held</span>}
                </span>
              </div>
              {mailto && (
                <a href={mailto} className="mt-1 inline-block text-[11px] text-ink-3 underline underline-offset-2">
                  Something looks wrong?
                </a>
              )}
            </li>
          );
        })}
      </ul>
      {s.lines.length === 0 && <p className="mt-3 text-[13px] text-ink-2">Nothing in this period yet.</p>}
    </div>
  );
}
