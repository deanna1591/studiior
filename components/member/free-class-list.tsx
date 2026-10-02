"use client";

import { useState, useTransition } from "react";
import { fmtDayLong, fmtTime } from "@/lib/time";
import type { BookResult } from "@/app/member/actions";

type FreeClass = {
  occurrence_id: string; name: string; starts_at: string; room_name: string | null;
  instructor_first: string | null; headcount: number; capacity: number; free_bookable: boolean;
};

/**
 * Decision 30 amendment — the free booker's list. Only eligible classes, fullest
 * first (the server orders them). A capped class shows "Full for free classes"
 * and cannot be booked with the free seat; everything else books as the free
 * first class and lands "Waiting for confirmation" until the class is on.
 */
export default function FreeClassList({
  classes, timeZone, bookFirstFree,
}: {
  classes: FreeClass[]; timeZone: string;
  bookFirstFree: (p: BookResult, f: FormData) => Promise<BookResult>;
}) {
  const [pending, start] = useTransition();
  const [done, setDone] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  if (classes.length === 0) return null;

  const book = (id: string) => start(async () => {
    const f = new FormData();
    f.set("occurrence_id", id);
    const r = await bookFirstFree({ ok: false, message: "" }, f);
    if (r && r.ok) { setDone(id); setErr(null); } else setErr(r?.message ?? "That didn't work — please try again.");
  });

  return (
    <section aria-label="Your free class" className="mb-5">
      <h2 className="m-head mb-1 text-[16px] leading-5 text-ink">Your free class — pick one.</h2>
      <p className="m-sub mb-3 text-[12.5px] leading-[18px] text-ink-2">
        Classes with people already in are first.
      </p>
      {err && (
        <p className="mb-2 rounded-lg px-3 py-2 text-[12.5px] leading-[18px]"
           style={{ background: "var(--coral-tint)", color: "var(--ink)" }}>{err}</p>
      )}
      <ul className="space-y-2">
        {classes.map((c) => {
          const booked = done === c.occurrence_id;
          return (
            <li key={c.occurrence_id}
                className="flex items-center gap-3 rounded-2xl bg-surface px-3.5 py-3"
                style={{ boxShadow: "0 1px 3px rgb(26 21 18 / 0.06), 0 6px 20px rgb(26 21 18 / 0.05)" }}>
              <div className="min-w-0 flex-1">
                <div className="flex items-baseline gap-2">
                  <span className="num text-[15px] font-semibold text-ink">{fmtTime(c.starts_at, timeZone)}</span>
                  <span className="m-body truncate text-ink">{c.name}</span>
                </div>
                <div className="m-micro mt-0.5 text-ink-3">
                  {fmtDayLong(c.starts_at, timeZone)}
                  {[c.instructor_first, c.room_name].filter(Boolean).length > 0 && " · "}
                  {[c.instructor_first, c.room_name].filter(Boolean).join(" · ")}
                </div>
              </div>
              {booked ? (
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
    </section>
  );
}
