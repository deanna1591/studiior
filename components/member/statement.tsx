"use client";

import { useState } from "react";
import Link from "next/link";
import { formatMoney } from "@/lib/plans";
import { filterStatement, groupByMonth, type StatementRow } from "@/lib/statement";
import type { TimeFormat } from "@/lib/time";

/**
 * Decision 75a — the member activity statement. Month groups, a filter (All /
 * Classes / Credits & payments) and a running balance on the rows that move
 * credit. Rows tap through to the class (occurrence) or the plan (purchase).
 */
const TABS: { key: "all" | "classes" | "credits"; label: string }[] = [
  { key: "all", label: "All" },
  { key: "classes", label: "Classes" },
  { key: "credits", label: "Credits & payments" },
];

function href(r: StatementRow): string | null {
  if (r.occurrence_id) return `/class/${r.occurrence_id}`;
  if (r.membership_id) return "/account/plan";
  return null;
}

export default function Statement({ rows, timeZone, timeFormat }:
  { rows: StatementRow[]; timeZone: string; timeFormat: TimeFormat }) {
  const [which, setWhich] = useState<"all" | "classes" | "credits">("all");
  const monthLabel = (at: string) =>
    new Intl.DateTimeFormat("en-GB", { timeZone, month: "long", year: "numeric" }).format(new Date(at));
  const dayLabel = (at: string) =>
    new Intl.DateTimeFormat("en-GB", { timeZone, day: "2-digit", month: "short" }).format(new Date(at));

  const groups = groupByMonth(filterStatement(rows, which), monthLabel);

  return (
    <div>
      <div className="mb-4 flex gap-1.5">
        {TABS.map((t) => (
          <button key={t.key} type="button" onClick={() => setWhich(t.key)}
            className={`m-press rounded-full px-3 py-1.5 text-[12px] font-medium leading-4 ${
              which === t.key ? "text-ink" : "text-ink-3"}`}
            style={which === t.key ? { background: "var(--accent-chip)" } : { background: "var(--surface)", border: "1px solid var(--line)" }}>
            {t.label}
          </button>
        ))}
      </div>

      {groups.length === 0 ? (
        <div className="m-card p-5 text-center">
          <p className="m-body text-ink">Nothing here yet.</p>
          <p className="m-sub mt-1 text-ink-2">
            <Link href="/book" className="text-lime-text underline underline-offset-4">Find a class to book</Link> and it will show up here.
          </p>
        </div>
      ) : (
        <div className="space-y-5">
          {groups.map((g) => (
            <section key={g.label}>
              <h2 className="m-micro mb-1.5 uppercase tracking-[0.06em] text-ink-3">{g.label}</h2>
              <ul className="m-card divide-y divide-line overflow-hidden">
                {g.items.map((r, i) => {
                  const cd = r.credit_delta ?? 0;
                  const to = href(r);
                  const body = (
                    <>
                      <span className="min-w-0 flex-1">
                        <span className="m-body block truncate text-ink">{r.title}</span>
                        <span className="m-micro block text-ink-3">
                          {dayLabel(r.at)}
                          {r.detail && <> · {r.detail}</>}
                          {cd !== 0 && (
                            <> · <span className="num">{cd > 0 ? "+" : ""}{cd}</span> credit{Math.abs(cd) === 1 ? "" : "s"}</>
                          )}
                        </span>
                      </span>
                      <span className="shrink-0 pl-2 text-right">
                        {r.amount_cents != null && r.currency && (
                          <span className="num block text-[13px] text-ink">{formatMoney(r.amount_cents, r.currency)}</span>
                        )}
                        {(cd !== 0 || r.amount_cents != null) && r.balance_after != null && (
                          <span className="m-micro block text-ink-3">Balance <span className="num">{r.balance_after}</span></span>
                        )}
                      </span>
                    </>
                  );
                  return (
                    <li key={`${r.kind}-${r.at}-${i}`}>
                      {to ? (
                        <Link href={to} className="m-press flex items-center gap-3 px-3 py-2.5">{body}</Link>
                      ) : (
                        <div className="flex items-center gap-3 px-3 py-2.5">{body}</div>
                      )}
                    </li>
                  );
                })}
              </ul>
            </section>
          ))}
        </div>
      )}
    </div>
  );
}
