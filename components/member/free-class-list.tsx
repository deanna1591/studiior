"use client";

import { useMemo, useState, useTransition } from "react";
import { fmtTime, zonedDateKey } from "@/lib/time";
import type { BookResult } from "@/app/member/actions";
import type { TimeFormat } from "@/lib/time";

type FreeClass = {
  occurrence_id: string; name: string; starts_at: string; room_name: string | null;
  instructor_first: string | null; headcount: number; capacity: number; free_bookable: boolean;
};

/**
 * Decision 55 — the free booker's day strip (replacing the Decision 30 amendment
 * flat list). Only eligible classes come in; they are grouped by studio-local
 * day. The strip marks (a dot) every day with one and opens on the first such
 * day; a day with none shows the "try another day" line. Each row: time (per the
 * studio's format), class, instructor, room, a "{n} going" chip, and Book free;
 * a cap-full class is muted and unbookable. The member picks their one free
 * class; once booked they are no longer eligible and the picker disappears.
 */
export default function FreeClassList({
  classes, timeZone, timeFormat = "24h", bookFirstFree,
}: {
  classes: FreeClass[]; timeZone: string; timeFormat?: TimeFormat;
  bookFirstFree: (p: BookResult, f: FormData) => Promise<BookResult>;
}) {
  const [pending, start] = useTransition();
  const [booked, setBooked] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  // Group by studio-local day; build the continuous day span first→last eligible.
  const { days, byDay, firstKey } = useMemo(() => {
    const byDay = new Map<string, FreeClass[]>();
    for (const c of classes) {
      const k = zonedDateKey(c.starts_at, timeZone);
      (byDay.get(k) ?? byDay.set(k, []).get(k)!).push(c);
    }
    const withClasses = [...byDay.keys()].sort();
    const days: { key: string; label: string; dow: string; hasClasses: boolean }[] = [];
    if (withClasses.length) {
      const first = new Date(`${withClasses[0]}T00:00:00Z`);
      const last = new Date(`${withClasses[withClasses.length - 1]}T00:00:00Z`);
      for (let d = new Date(first); d <= last; d = new Date(d.getTime() + 86_400_000)) {
        const key = d.toISOString().slice(0, 10);
        days.push({
          key,
          label: String(d.getUTCDate()),
          dow: new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", weekday: "short" }).format(d),
          hasClasses: byDay.has(key),
        });
      }
    }
    return { days, byDay, firstKey: withClasses[0] ?? null };
  }, [classes, timeZone]);

  const [selected, setSelected] = useState<string | null>(firstKey);
  if (classes.length === 0 || !firstKey) return null;
  const key = selected ?? firstKey;
  const rows = (byDay.get(key) ?? []).slice().sort((a, b) => a.starts_at.localeCompare(b.starts_at));

  const book = (id: string) => start(async () => {
    const f = new FormData();
    f.set("occurrence_id", id);
    const r = await bookFirstFree({ ok: false, message: "" }, f);
    if (r && r.ok) { setBooked(id); setErr(null); } else setErr(r?.message ?? "That didn't work — please try again.");
  });

  return (
    <section aria-label="Your free class" className="mb-5">
      <h2 className="m-head mb-1 text-[16px] leading-5 text-ink">Your free class — pick one.</h2>
      <p className="m-sub mb-3 text-[12.5px] leading-[18px] text-ink-2">
        Days with people already in are a good bet.
      </p>

      {/* Day strip: a dot marks a day with at least one eligible class. */}
      <div className="mb-3 flex gap-1.5 overflow-x-auto pb-1" role="tablist" aria-label="Pick a day">
        {days.map((d) => {
          const on = d.key === key;
          return (
            <button key={d.key} role="tab" aria-selected={on} onClick={() => setSelected(d.key)}
                    className="m-press flex min-w-[46px] flex-col items-center rounded-2xl px-1 py-1.5"
                    style={on
                      ? { background: "var(--accent-solid)", color: "var(--accent-on-solid)" }
                      : { background: "var(--surface)", color: "var(--ink-2)",
                          boxShadow: "0 1px 3px rgb(26 21 18 / 0.06)" }}>
              <span className="text-[10px] uppercase tracking-wide">{d.dow}</span>
              <span className="num text-[15px] font-semibold leading-5">{d.label}</span>
              <span className="mt-0.5 h-1 w-1 rounded-full"
                    style={{ background: d.hasClasses
                      ? (on ? "var(--accent-on-solid)" : "var(--lime-text)") : "transparent" }} />
            </button>
          );
        })}
      </div>

      {err && (
        <p className="mb-2 rounded-lg px-3 py-2 text-[12.5px] leading-[18px]"
           style={{ background: "var(--coral-tint)", color: "var(--ink)" }}>{err}</p>
      )}

      {rows.length === 0 ? (
        <p className="rounded-2xl bg-surface px-3.5 py-6 text-center text-[13px] leading-[19px] text-ink-2"
           style={{ boxShadow: "0 1px 3px rgb(26 21 18 / 0.06)" }}>
          No free-class slots this day — try another day.
        </p>
      ) : (
        <ul className="space-y-2">
          {rows.map((c) => {
            const isBooked = booked === c.occurrence_id;
            const muted = !c.free_bookable;
            return (
              <li key={c.occurrence_id}
                  className="flex items-center gap-3 rounded-2xl bg-surface px-3.5 py-3"
                  style={{ boxShadow: "0 1px 3px rgb(26 21 18 / 0.06), 0 6px 20px rgb(26 21 18 / 0.05)",
                           opacity: muted && !isBooked ? 0.72 : 1 }}>
                <div className="min-w-0 flex-1">
                  <div className="flex items-baseline gap-2">
                    <span className="num text-[15px] font-semibold text-ink">{fmtTime(c.starts_at, timeZone, timeFormat)}</span>
                    <span className="m-body truncate text-ink">{c.name}</span>
                  </div>
                  <div className="m-micro mt-0.5 flex items-center gap-1.5 text-ink-3">
                    <span className="truncate">{[c.instructor_first, c.room_name].filter(Boolean).join(" · ")}</span>
                    {c.headcount > 0 && (
                      <span className="shrink-0 rounded-full px-1.5 py-0.5 text-[10px] font-medium"
                            style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>
                        {c.headcount} going
                      </span>
                    )}
                  </div>
                </div>
                {isBooked ? (
                  <span className="shrink-0 text-[12.5px] font-medium text-ink-2">Waiting for confirmation</span>
                ) : c.free_bookable ? (
                  <button onClick={() => book(c.occurrence_id)} disabled={pending}
                          className="m-press shrink-0 rounded-full px-3.5 py-2 text-[13px] font-semibold disabled:opacity-60"
                          style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>
                    {pending ? "…" : "Book free"}
                  </button>
                ) : (
                  <span className="shrink-0 text-[12px] text-ink-3">Full for free classes</span>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
