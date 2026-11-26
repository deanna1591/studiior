"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { formatMoney } from "@/lib/format-money";
import { cancelCode } from "../actions";

export type CodeRow = {
  code_id: string; code: string; state: "unused" | "used" | "expired" | "cancelled";
  used_by: string | null; used_email: string | null; used_at: string | null; plan: string | null;
  amount_off_cents: number | null; currency: string;
};
const LABEL: Record<CodeRow["state"], string> = { unused: "Unused", used: "Used", expired: "Expired", cancelled: "Cancelled" };
const FILTERS = ["all", "unused", "used", "expired", "cancelled"] as const;

export default function CodeRows({ batchId, kind, rows, timeZone }: {
  batchId: string; kind: "batch" | "shared"; rows: CodeRow[]; timeZone: string;
}) {
  const [filter, setFilter] = useState<(typeof FILTERS)[number]>("all");
  const [copied, setCopied] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const router = useRouter();
  const shown = rows.filter((r) => filter === "all" || r.state === filter);
  const when = (iso: string) => new Intl.DateTimeFormat("en-GB", { timeZone, day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }).format(new Date(iso));

  async function copy(text: string, key: string) {
    try { await navigator.clipboard.writeText(text); setCopied(key); setTimeout(() => setCopied(null), 1500); } catch { /* ignore */ }
  }
  const uniqueCodes = Array.from(new Set(shown.map((r) => r.code)));

  return (
    <div className="max-w-4xl">
      <div className="mb-3 flex flex-wrap items-center gap-2">
        {FILTERS.map((f) => (
          <button key={f} type="button" onClick={() => setFilter(f)}
                  className={`rounded-full border px-3 py-1 text-[12px] font-semibold ${filter === f ? "border-ink bg-ink text-surface" : "border-line text-ink"}`}>
            {f === "all" ? "All" : LABEL[f]} <span className="num">{f === "all" ? rows.length : rows.filter((r) => r.state === f).length}</span>
          </button>
        ))}
        <span className="ml-auto flex gap-2">
          <button type="button" onClick={() => copy(uniqueCodes.join("\n"), "all")}
                  className="rounded border border-line px-3 py-1 text-[12px] font-semibold text-ink">
            {copied === "all" ? "Copied" : "Copy all"}
          </button>
          <a href={`/settings/promotions/codes/${batchId}/export`}
             className="rounded border border-line px-3 py-1 text-[12px] font-semibold text-ink">Download CSV</a>
        </span>
      </div>
      {msg && <p className="mb-2 text-[13px] text-ink">{msg}</p>}
      <div className="overflow-x-auto rounded border border-line bg-surface">
        <table className="w-full text-left text-[13px]">
          <thead className="text-[12px] text-ink-2">
            <tr className="border-b border-line">
              <th className="px-3 py-2 font-semibold">Code</th><th className="px-3 py-2 font-semibold">State</th>
              <th className="px-3 py-2 font-semibold">Used by</th><th className="px-3 py-2 font-semibold">When</th>
              <th className="px-3 py-2 font-semibold">Plan</th><th className="px-3 py-2 font-semibold text-right">Off</th>
              <th className="px-3 py-2" />
            </tr>
          </thead>
          <tbody>
            {shown.map((r, i) => (
              <tr key={r.code_id + i} className="border-b border-line last:border-0">
                <td className="px-3 py-2 font-mono text-ink">{r.code}</td>
                <td className="px-3 py-2 text-ink">{LABEL[r.state]}</td>
                <td className="px-3 py-2 text-ink">{r.used_by ?? ""}{r.used_email && r.used_by !== r.used_email ? <span className="block text-[11px] text-ink-2">{r.used_email}</span> : null}</td>
                <td className="px-3 py-2 text-ink-2">{r.used_at ? when(r.used_at) : ""}</td>
                <td className="px-3 py-2 text-ink-2">{r.plan ?? ""}</td>
                <td className="num px-3 py-2 text-right text-ink">{r.amount_off_cents ? `-${formatMoney(r.amount_off_cents, r.currency)}` : ""}</td>
                <td className="whitespace-nowrap px-3 py-2 text-right">
                  <button type="button" onClick={() => copy(r.code, r.code_id + i)} className="text-[12px] text-ink underline underline-offset-4">
                    {copied === r.code_id + i ? "Copied" : "Copy"}
                  </button>
                  {r.state === "unused" && (kind === "batch" || i === 0) && (
                    <button type="button" disabled={pending}
                            onClick={() => { if (!confirm(`Cancel ${r.code}? It will stop working.`)) return;
                              start(async () => { const x = await cancelCode(r.code_id, batchId); setMsg(x.ok ? `${r.code} is cancelled.` : x.message ?? null); router.refresh(); }); }}
                            className="ml-3 text-[12px] text-ink underline underline-offset-4">Cancel</button>
                  )}
                </td>
              </tr>
            ))}
            {shown.length === 0 && <tr><td colSpan={7} className="px-3 py-4 text-ink-2">Nothing here.</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}
