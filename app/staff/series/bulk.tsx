"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { TierMark, type Tier } from "@/components/tier-mark";
import { previewBulk, applyBulk, type BulkResult } from "./bulk-actions";

export type BulkSeries = {
  id: string; name: string; meta: string; open: boolean;
  tier?: Tier; minimum: number | null; freeFirst?: boolean;
};
type Opt = { id: string; name: string };

const CHANGE_TYPES: { v: string; label: string; needsTier: boolean }[] = [
  { v: "minimum",    label: "Minimum bookings",    needsTier: true },
  { v: "tier",       label: "Tier",                needsTier: true },
  { v: "room",       label: "Room",                needsTier: false },
  { v: "ends_on",    label: "End date",            needsTier: false },
  { v: "starts_on",  label: "Start date",          needsTier: false },
  { v: "instructor", label: "Template instructor", needsTier: false },
  { v: "free_first",  label: "Accepts free first classes", needsTier: false },
];

/**
 * Decision 42b — select recurring classes and apply one change to all. The bar
 * and the row checkboxes share this component's selection state. Preview runs
 * the real database functions in a savepoint and rolls back; Apply performs it.
 */
export default function BulkManage({
  series, rooms, instructors, showTier, flexMin, freeFirstOn,
}: {
  series: BulkSeries[]; rooms: Opt[]; instructors: Opt[]; showTier: boolean; flexMin: number;
  freeFirstOn: boolean;
}) {
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [ct, setCt] = useState("minimum");
  const [vals, setVals] = useState<Record<string, string>>({});
  const [res, setRes] = useState<BulkResult>(null);
  const [pending, start] = useTransition();

  const types = CHANGE_TYPES.filter((t) => showTier || !t.needsTier);
  const allIds = series.map((s) => s.id);
  const allOn = sel.size > 0 && allIds.every((id) => sel.has(id));
  const v = (k: string) => vals[k] ?? "";
  const setV = (k: string, val: string) => setVals((p) => ({ ...p, [k]: val }));

  const toggle = (id: string) =>
    setSel((p) => { const n = new Set(p); n.has(id) ? n.delete(id) : n.add(id); return n; });
  const toggleAll = () =>
    setSel(allOn ? new Set() : new Set(allIds));

  function form(): FormData {
    const f = new FormData();
    sel.forEach((id) => f.append("ids", id));
    f.set("change_type", ct);
    for (const [k, val] of Object.entries(vals)) f.set(k, val);
    return f;
  }
  const doPreview = () => start(async () => setRes(await previewBulk(null, form())));
  const doApply = () => start(async () => {
    const r = await applyBulk(null, form());
    setRes(r);
    if (r && "ok" in r && !r.preview) setSel(new Set());
  });

  const sentence = (r: Extract<BulkResult, { ok: true }>) => {
    const n = r.changed.length, m = r.refused.length;
    const parts = [`Changed ${n} recurring ${n === 1 ? "class" : "classes"}.`];
    if (m > 0) parts.push(`${m} refused: ` + r.refused.map((x) => `${x.name} ${x.when} — ${x.reason}`).join("; ") + ".");
    const sa = r.warnings.filter((w) => w.code === "standalone_flex").length;
    if (sa > 0) parts.push(`${sa} now ${sa === 1 ? "has a flex class" : "have flex classes"} with nothing beside it — check the standby fee.`);
    return parts.join(" ");
  };

  return (
    <div>
      {/* The change bar. Stacks at phone width (flex-wrap). */}
      <div className="mb-4 rounded border border-line bg-surface p-3">
        <div className="flex flex-wrap items-end gap-2">
          <label className="flex flex-col gap-1 text-[12px] text-ink-2">
            Change
            <select value={ct} onChange={(e) => { setCt(e.target.value); setRes(null); }}
                    className="rounded border border-line bg-paper px-2 py-1.5 text-[13px] text-ink">
              {types.map((t) => <option key={t.v} value={t.v}>{t.label}</option>)}
            </select>
          </label>

          {ct === "minimum" && (
            <label className="flex flex-col gap-1 text-[12px] text-ink-2">To
              <input type="number" min={0} value={v("minimum")} onChange={(e) => setV("minimum", e.target.value)}
                     className="w-24 rounded border border-line bg-paper px-2 py-1.5 text-[13px] text-ink" /></label>
          )}
          {ct === "tier" && (
            <>
              <label className="flex flex-col gap-1 text-[12px] text-ink-2">Tier
                <select value={v("tier")} onChange={(e) => setV("tier", e.target.value)}
                        className="rounded border border-line bg-paper px-2 py-1.5 text-[13px] text-ink">
                  <option value="">—</option><option value="core">Core</option>
                  <option value="flex">Flex</option><option value="always">Always</option>
                </select></label>
              {v("tier") === "flex" && (
                <label className="flex flex-col gap-1 text-[12px] text-ink-2">Minimum
                  <input type="number" min={1} value={v("minimum")} onChange={(e) => setV("minimum", e.target.value)}
                         className="w-24 rounded border border-line bg-paper px-2 py-1.5 text-[13px] text-ink" /></label>
              )}
            </>
          )}
          {ct === "room" && (
            <label className="flex flex-col gap-1 text-[12px] text-ink-2">To
              <select value={v("room_id")} onChange={(e) => setV("room_id", e.target.value)}
                      className="rounded border border-line bg-paper px-2 py-1.5 text-[13px] text-ink">
                <option value="">—</option>{rooms.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
              </select></label>
          )}
          {ct === "free_first" && (
            <label className="flex flex-col gap-1 text-[12px] text-ink-2">To
              <select value={v("free_first_allowed") || "on"} onChange={(e) => setV("free_first_allowed", e.target.value)}
                      className="rounded border border-line bg-paper px-2 py-1.5 text-[13px] text-ink">
                <option value="on">Accepts free classes</option>
                <option value="off">No free classes</option>
              </select></label>
          )}
          {ct === "ends_on" && (
            <label className="flex flex-col gap-1 text-[12px] text-ink-2">End (blank = no end)
              <input type="date" value={v("ends_on")} onChange={(e) => setV("ends_on", e.target.value)}
                     className="rounded border border-line bg-paper px-2 py-1.5 text-[13px] text-ink" /></label>
          )}
          {ct === "starts_on" && (
            <label className="flex flex-col gap-1 text-[12px] text-ink-2">Start
              <input type="date" value={v("starts_on")} onChange={(e) => setV("starts_on", e.target.value)}
                     className="rounded border border-line bg-paper px-2 py-1.5 text-[13px] text-ink" /></label>
          )}
          {ct === "instructor" && (
            <label className="flex flex-col gap-1 text-[12px] text-ink-2">To
              <select value={v("instructor_id")} onChange={(e) => setV("instructor_id", e.target.value)}
                      className="rounded border border-line bg-paper px-2 py-1.5 text-[13px] text-ink">
                <option value="">Unassigned</option>{instructors.map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}
              </select></label>
          )}

          <button type="button" onClick={doPreview} disabled={pending || sel.size === 0}
                  className="rounded border border-line bg-paper px-3 py-1.5 text-[13px] font-medium text-ink hover:opacity-80 disabled:opacity-50">
            Preview {sel.size > 0 ? `(${sel.size})` : ""}
          </button>
        </div>
        {sel.size === 0 && <p className="mt-2 text-[12px] text-ink-3">Tick the classes to change, then Preview.</p>}
      </div>

      {/* Preview table / apply result. */}
      {res && "error" in res && res.error && (
        <div className="mb-4 border-l-[3px] bg-coral-tint px-3 py-2 text-[13px] leading-[19px] text-ink"
             style={{ borderLeftColor: "var(--coral)" }} role="alert">{res.error}</div>
      )}
      {res && "ok" in res && res.preview && (
        <div className="mb-4 rounded border border-line bg-surface p-3">
          <div className="overflow-x-auto">
            <table className="w-full min-w-[32rem] text-[13px]">
              <thead><tr className="text-left text-[12px] text-ink-2">
                <th className="py-1 pr-3 font-medium">Recurring class</th>
                <th className="py-1 pr-3 font-medium">Change</th>
                <th className="py-1 font-medium">Note</th></tr></thead>
              <tbody>
                {res.changed.map((r) => (
                  <tr key={r.series_id} className="border-t border-line">
                    <td className="py-1.5 pr-3 text-ink">{r.name} <span className="text-ink-3">{r.when}</span></td>
                    <td className="py-1.5 pr-3 num text-ink">{r.current} → {r.new}</td>
                    <td className="py-1.5 text-ink-3">
                      {res.warnings.some((w) => w.series_id === r.series_id && w.code === "standalone_flex") ? "standalone flex" : ""}
                    </td>
                  </tr>
                ))}
                {res.refused.map((r) => (
                  <tr key={r.series_id} className="border-t border-line">
                    <td className="py-1.5 pr-3 text-ink">{r.name} <span className="text-ink-3">{r.when}</span></td>
                    <td className="py-1.5 pr-3 text-ink-3">no change</td>
                    <td className="py-1.5 text-ink">{r.reason}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="mt-3 flex items-center gap-2">
            <button type="button" onClick={doApply} disabled={pending || res.changed.length === 0}
                    className="rounded-lg border bg-coral-tint px-3 py-1.5 text-[12.5px] font-medium text-ink disabled:opacity-50"
                    style={{ borderColor: "var(--coral)" }}>
              Apply to {res.changed.length} {res.changed.length === 1 ? "class" : "classes"}
            </button>
            <button type="button" onClick={() => setRes(null)} className="text-[12px] text-ink-3 hover:text-ink">Cancel</button>
          </div>
        </div>
      )}
      {res && "ok" in res && !res.preview && (
        <div className="mb-4 border-l-[3px] bg-paper px-3 py-2 text-[13px] leading-[19px] text-ink"
             style={{ borderLeftColor: "var(--lime-text)" }} role="status">{sentence(res)}</div>
      )}

      {/* The selectable list. */}
      <div className="mb-2 flex items-center gap-2 text-[12px] text-ink-2">
        <label className="flex items-center gap-1.5">
          <input type="checkbox" checked={allOn} onChange={toggleAll} aria-label="Select all or none" />
          Select {allOn ? "none" : "all"}
        </label>
        <span className="text-ink-3">· {sel.size} selected</span>
      </div>
      <ul className="divide-y divide-line rounded border border-line bg-surface">
        {series.map((s) => (
          <li key={s.id} className="flex items-center gap-3 px-3.5 py-2.5">
            <input type="checkbox" checked={sel.has(s.id)} onChange={() => toggle(s.id)}
                   aria-label={`Select ${s.name}`} />
            <span className="min-w-0 flex-1">
              <Link href={`/series/${s.id}`} className="truncate text-[14px] leading-5 text-ink hover:underline">
                {showTier && s.tier && <span className="mr-1.5"><TierMark tier={s.tier} /></span>}
                {s.name}
              </Link>
              {freeFirstOn && s.freeFirst && (
                <span className="ml-1.5 inline-block rounded px-1.5 py-0.5 text-[10px] font-medium align-middle"
                      style={{ background: "var(--accent-chip)", color: "var(--ink)" }}
                      title="Accepts free first classes">free</span>
              )}
              <span className="block text-[12px] leading-4 text-ink-3">{s.meta}</span>
            </span>
            {s.open && <span className="num shrink-0 text-[13px] text-ink-2">open</span>}
          </li>
        ))}
      </ul>
    </div>
  );
}
