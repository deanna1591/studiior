"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { spotsLine, type RescueCard } from "@/lib/flex-rescue";
import type { MoveResult } from "@/app/member/actions";

// A move succeeds, and a second attempt on an already-moved booking comes back
// source_confirmed. This guard fires the move exactly once per (booking, target)
// for the page's lifetime: a module Set survives React's dev remount of the
// effect (a component ref does not) and any fast re-render.
const started = new Set<string>();

/**
 * Decision 95 — the move page body. With a target in the URL it fires the move
 * once on mount (the GET did not mutate, so an email prefetch is safe) and shows
 * "You're in. ..." or the refusal sentence. The list of core classes sits below
 * either way, so a refusal still leads somewhere and a bare /move is a picker.
 */
export default function MovePanel({
  bookingId, targetId, sourceName, cards, move,
}: {
  bookingId: string;
  targetId: string | null;
  sourceName: string;
  cards: RescueCard[];
  move: (bookingId: string, targetId: string) => Promise<MoveResult>;
}) {
  const [result, setResult] = useState<MoveResult | null>(null);
  const [moving, setMoving] = useState(!!(bookingId && targetId));

  useEffect(() => {
    if (!(bookingId && targetId)) return;
    const key = `${bookingId}:${targetId}`;
    if (started.has(key)) return;
    started.add(key);
    let live = true;
    move(bookingId, targetId).then((r) => { if (live) { setResult(r); setMoving(false); } });
    return () => { live = false; };
  }, [bookingId, targetId, move]);

  const done = result?.ok;

  return (
    <div className="pb-24">
      <h1 className="m-head text-[22px] text-ink">Move your booking</h1>

      {moving && (
        <p className="m-sub mt-3 text-ink-2">Moving you…</p>
      )}

      {result && (
        <div className="m-card mt-3 p-4" style={done ? { background: "var(--accent-chip)" } : undefined}>
          <p className="m-body font-medium text-ink">{result.message}</p>
          {done && (
            <Link href="/" className="m-sub mt-2 inline-block text-ink-2 underline underline-offset-2">
              Back to Home
            </Link>
          )}
        </div>
      )}

      {!done && (
        <>
          <p className="m-sub mt-4 text-ink-2">
            {cards.length > 0
              ? `Pick a class that is already going ahead. Your spot in ${sourceName} moves with you, nothing else to do.`
              : "There is nothing else on in the next week to move to right now."}
          </p>

          <div className="mt-4 space-y-3">
            {cards.map((c) => (
              <div key={c.occurrence_id} className="m-card p-4">
                <p className="m-body font-semibold text-ink">{c.name}</p>
                <p className="m-sub mt-0.5 text-ink-2">
                  {[c.day_label, c.time_label, c.coach_first ? `with ${c.coach_first}` : null]
                    .filter(Boolean)
                    .join(" · ")}
                </p>
                <p className="m-micro mt-0.5 text-ink-3">{spotsLine(c)}</p>
                <Link
                  href={`/move?booking=${encodeURIComponent(bookingId)}&target=${encodeURIComponent(c.occurrence_id)}`}
                  style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
                  className="m-tap m-press mt-3 inline-block rounded-full px-4 text-[13px] font-bold"
                >
                  Move me to this class
                </Link>
              </div>
            ))}
          </div>

          <Link href="/book" className="m-sub mt-5 inline-block text-ink-2 underline underline-offset-2">
            See the full schedule
          </Link>
        </>
      )}
    </div>
  );
}
