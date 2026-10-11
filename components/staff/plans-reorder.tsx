"use client";

import { useRef, useState, useTransition } from "react";
import Link from "next/link";
import { reorderPlans, setPlanFeature } from "@/app/staff/plans/actions";

/** One live plan as the reorder list needs it — the display strings are built
 *  server-side so this component stays about ordering, not formatting. */
export type ReorderPlan = {
  id: string;
  name: string;
  meta: string;
  price: string;
  right: string;
  featured: boolean;
  badge: string | null;
};

/**
 * Decision 74: the staff Plans list, reorderable. Drag (HTML5, pointer — no new
 * dependency) with Up/Down buttons as the keyboard/touch fallback; a Featured
 * toggle and a badge input per row. Reordering is local until "Save order",
 * which calls reorder_plans ONCE; Featured/badge save immediately through
 * setPlanFeature. Archived plans are rendered separately by the page and are not
 * reorderable.
 */
export default function PlansReorder({ plans }: { plans: ReorderPlan[] }) {
  const [order, setOrder] = useState<ReorderPlan[]>(plans);
  const [baseline, setBaseline] = useState<string[]>(plans.map((p) => p.id));
  const [msg, setMsg] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const dragFrom = useRef<number | null>(null);

  const dirty = order.map((p) => p.id).join() !== baseline.join();

  const move = (i: number, dir: -1 | 1) => {
    const j = i + dir;
    if (j < 0 || j >= order.length) return;
    const next = [...order];
    [next[i], next[j]] = [next[j], next[i]];
    setOrder(next);
  };
  const onDrop = (i: number) => {
    const from = dragFrom.current;
    dragFrom.current = null;
    if (from == null || from === i) return;
    const next = [...order];
    const [moved] = next.splice(from, 1);
    next.splice(i, 0, moved);
    setOrder(next);
  };

  const saveFeature = (id: string, featured: boolean, badge: string | null) =>
    start(async () => {
      const r = await setPlanFeature(id, featured, badge);
      setMsg(r?.error ?? null);
    });

  const toggleFeatured = (i: number) => {
    const next = [...order];
    const p = { ...next[i], featured: !next[i].featured };
    next[i] = p;
    setOrder(next);
    saveFeature(p.id, p.featured, p.badge);
  };
  const setBadge = (i: number, v: string) => {
    const next = [...order];
    next[i] = { ...next[i], badge: v };
    setOrder(next);
  };
  const commitBadge = (i: number) => {
    const p = order[i];
    const b = plans.find((q) => q.id === p.id);
    if ((b?.badge ?? "") !== (p.badge ?? "")) saveFeature(p.id, p.featured, p.badge);
  };

  const saveOrder = () =>
    start(async () => {
      const ids = order.map((p) => p.id);
      const r = await reorderPlans(ids);
      if (r?.error) { setMsg(r.error); return; }
      setBaseline(ids);
      setMsg(null);
    });

  return (
    <div>
      <div className="mb-2 flex items-center justify-between gap-3">
        <p className="text-[12px] leading-4 text-ink-3">
          Drag a plan, or use the arrows, to set the order members see. Featured
          plans show first, with their badge.
        </p>
        <button
          type="button"
          onClick={saveOrder}
          disabled={!dirty || pending}
          className="shrink-0 rounded bg-ink px-3 py-1.5 text-[13px] font-medium leading-[18px] text-paper hover:bg-ink-2 disabled:opacity-40"
        >
          {pending ? "Saving…" : dirty ? "Save order" : "Saved"}
        </button>
      </div>
      {msg && <p className="mb-2 text-[12px] leading-4 text-coral">{msg}</p>}

      <ul className="overflow-hidden rounded-lg border border-line bg-surface">
        {order.map((p, i) => (
          <li
            key={p.id}
            draggable
            onDragStart={() => { dragFrom.current = i; }}
            onDragOver={(e) => e.preventDefault()}
            onDrop={() => onDrop(i)}
            data-plan={p.id}
            className="flex items-center gap-3 border-b border-line px-3 py-2.5 last:border-b-0"
          >
            <span className="cursor-grab select-none text-[15px] leading-none text-ink-3" aria-hidden title="Drag to reorder">⠿</span>
            <div className="flex flex-col gap-0.5">
              <button type="button" aria-label="Move up" onClick={() => move(i, -1)} disabled={i === 0}
                      className="h-4 w-4 text-[10px] leading-none text-ink-3 hover:text-ink disabled:opacity-30">▲</button>
              <button type="button" aria-label="Move down" onClick={() => move(i, 1)} disabled={i === order.length - 1}
                      className="h-4 w-4 text-[10px] leading-none text-ink-3 hover:text-ink disabled:opacity-30">▼</button>
            </div>

            <Link href={`/plans/${p.id}`} className="min-w-0 flex-1 hover:underline">
              <div className="flex items-center gap-2 truncate text-[14px] leading-5 text-ink">
                {p.name}
                {p.badge && (
                  <span className="shrink-0 rounded-sm px-1.5 py-px text-[11px] leading-4 text-ink"
                        style={{ background: "var(--accent-chip)" }}>{p.badge}</span>
                )}
              </div>
              <div className="truncate text-[12px] leading-4 text-ink-3">{p.meta}</div>
            </Link>

            <label className="flex shrink-0 cursor-pointer items-center gap-1.5 text-[12px] leading-4 text-ink-2">
              <input type="checkbox" checked={p.featured} onChange={() => toggleFeatured(i)} className="h-3.5 w-3.5" />
              Featured
            </label>
            <input
              type="text"
              value={p.badge ?? ""}
              maxLength={24}
              placeholder="Badge"
              onChange={(e) => setBadge(i, e.target.value)}
              onBlur={() => commitBadge(i)}
              className="w-28 shrink-0 rounded border border-line bg-paper px-2 py-1 text-[12px] leading-4 text-ink placeholder:text-ink-3"
            />

            <div className="shrink-0 text-right">
              <div className="num text-[13px] text-ink">{p.price}</div>
              <div className="text-[12px] leading-4 text-ink-3">{p.right}</div>
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}
