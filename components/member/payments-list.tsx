"use client";

import { useState } from "react";
import { PAYMENT_FILTERS } from "@/lib/wallet";
import type { PaymentRow } from "@/lib/wallet";

export type PaymentRowView = {
  key: string;
  kind: PaymentRow["kind"];
  chip: string;
  invoiceable: boolean;
  paymentId: string | null;
  item: string;
  dateLabel: string;
  amountLabel: string;
  refundLabel: string | null;
};

/**
 * Decision 88(c) — the Payments tab: one newest-first list with four filter
 * chips at the top (all shown by default). A chip toggles its kind; with none
 * selected everything shows. "Download invoice" sits on Paid and Refunded rows
 * and opens in a new tab (the route serves it as an attachment).
 */
export default function PaymentsList({ rows }: { rows: PaymentRowView[] }) {
  const [on, setOn] = useState<Set<PaymentRow["kind"]>>(new Set());
  const toggle = (k: PaymentRow["kind"]) =>
    setOn((prev) => {
      const next = new Set(prev);
      next.has(k) ? next.delete(k) : next.add(k);
      return next;
    });
  const shown = on.size === 0 ? rows : rows.filter((r) => on.has(r.kind));

  return (
    <>
      <div className="mb-4 flex flex-wrap gap-2">
        {PAYMENT_FILTERS.map((f) => {
          const active = on.has(f.key);
          return (
            <button key={f.key} type="button" onClick={() => toggle(f.key)}
                    aria-pressed={active}
                    className="m-sub m-press rounded-full px-3 py-1.5"
                    style={active
                      ? { background: "var(--accent-chip)", color: "var(--ink)", fontWeight: 700 }
                      : { color: "var(--ink-2)", border: "1px solid var(--line)" }}>
              {f.label}
            </button>
          );
        })}
      </div>

      {shown.length === 0 ? (
        <div className="m-card p-5 text-center"><p className="m-body text-ink">No payments here yet.</p></div>
      ) : (
        <ul className="m-card divide-y divide-line overflow-hidden">
          {shown.map((r) => (
            <li key={r.key} className="px-4 py-3">
              <div className="flex items-start justify-between gap-3">
                <span className="min-w-0">
                  <span className="m-body block text-ink">{r.item}</span>
                  <span className="m-micro block text-ink-3">{r.dateLabel}</span>
                  {r.refundLabel && <span className="m-micro block text-ink-3">{r.refundLabel}</span>}
                </span>
                <span className="shrink-0 text-right">
                  <span className="num block text-[15px] text-ink">{r.amountLabel}</span>
                  <span className="m-micro mt-0.5 inline-block rounded-full px-2.5 py-0.5"
                        style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>
                    {r.chip}
                  </span>
                </span>
              </div>
              {r.invoiceable && r.paymentId && (
                <a href={`/receipts/${r.paymentId}.pdf`} target="_blank" rel="noopener"
                   className="m-sub m-press mt-1.5 inline-block" style={{ color: "var(--lime-text)" }}>
                  Download invoice
                </a>
              )}
            </li>
          ))}
        </ul>
      )}
    </>
  );
}
