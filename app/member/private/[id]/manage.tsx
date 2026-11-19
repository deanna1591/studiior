"use client";

import { useEffect, useMemo, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { accentChip, accentSolid } from "@/lib/accent-pair";
import { fmtClock } from "@/lib/clock";
import { cancelIsOnTime, cancelNoticeLine, privateReasonSentence } from "@/lib/private-sessions";
import { cancelPrivate, movePrivate, privateSlots } from "../../book/private/actions";

export default function PrivateManage({
  occurrenceId, typeId, coachId, startsAt, timeZone, timeFormat, leadHours, isBooker, confirmed, polling,
}: {
  occurrenceId: string; typeId: string; coachId: string | null; startsAt: string; timeZone: string;
  timeFormat: "24h" | "12h"; leadHours: number; isBooker: boolean; confirmed: boolean; polling: boolean;
}) {
  const router = useRouter();
  const [now, setNow] = useState(() => Date.now());
  const [msg, setMsg] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const [moving, setMoving] = useState(false);
  const [confirmCancel, setConfirmCancel] = useState(false);
  const [starts, setStarts] = useState<string[]>([]);

  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 30000); return () => clearInterval(t); }, []);
  // A Xendit return: refresh until the webhook confirms (2 minutes at most).
  useEffect(() => {
    if (!polling) return;
    let n = 0;
    const t = setInterval(() => { n += 1; router.refresh(); if (n > 24) clearInterval(t); }, 5000);
    return () => clearInterval(t);
  }, [polling, router]);

  const startsMs = new Date(startsAt).getTime();
  const fmt = (ms: number) => {
    const iso = new Date(ms).toISOString();
    const d = new Intl.DateTimeFormat("en-GB", { timeZone, weekday: "short", day: "numeric", month: "short" }).format(new Date(ms));
    return `${fmtClock(iso, timeZone, timeFormat)} on ${d}`;
  };
  const onTime = cancelIsOnTime(startsMs, leadHours, now);
  const notice = cancelNoticeLine({ startsMs, leadHours, nowMs: now, fmt });

  const moveDays = useMemo(() => [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14], []);
  const [moveDay, setMoveDay] = useState(1);
  useEffect(() => {
    if (!moving) return;
    const from = new Date(Date.now() + (moveDay - 1) * 86400e3);
    const to = new Date(from.getTime() + 86400e3);
    privateSlots(typeId, coachId, from.toISOString(), to.toISOString()).then((r) => setStarts(r.starts));
  }, [moving, moveDay, typeId, coachId]);

  if (!isBooker || !confirmed) return null;

  function doCancel() {
    start(async () => {
      const r = await cancelPrivate(occurrenceId);
      if (!r.ok) { setMsg(r.reason ? privateReasonSentence(r.reason) : (r.message ?? "That didn't work.")); return; }
      setMsg(r.onTime ? "Cancelled. Your payment is back on your account." : "Cancelled. The fee was kept.");
      router.refresh();
    });
  }
  function doMove(s: string) {
    start(async () => {
      const r = await movePrivate(occurrenceId, s);
      if (!r.ok) { setMsg(r.reason ? privateReasonSentence(r.reason) : (r.message ?? "That didn't work.")); return; }
      setMsg(`Moved to ${fmt(new Date(s).getTime())}.`); setMoving(false);
      router.refresh();
    });
  }

  return (
    <div className="mt-4 space-y-3">
      <p className="m-sub text-ink-2">{notice}</p>
      {msg && <p className="rounded-lg px-3 py-2 text-[13px]" style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>{msg}</p>}
      {now < startsMs && (
        <div className="flex gap-2">
          {onTime && (
            <button type="button" onClick={() => setMoving((v) => !v)} disabled={pending}
              className="m-press flex-1 rounded-full py-3 text-[15px] font-semibold" style={accentChip()}>
              Move
            </button>
          )}
          <button type="button" onClick={() => onTime ? doCancel() : setConfirmCancel(true)} disabled={pending}
            className="m-press flex-1 rounded-full py-3 text-[15px] font-semibold"
            style={{ background: "var(--surface)", color: "var(--ink)", boxShadow: "inset 0 0 0 1.5px var(--ink)" }}>
            Cancel
          </button>
        </div>
      )}
      {confirmCancel && (
        <div className="m-card px-4 py-3">
          <p className="m-body text-ink">It&apos;s less than {leadHours} hours before the session. Cancelling now keeps the fee.</p>
          <div className="mt-3 flex gap-2">
            <button type="button" onClick={() => { setConfirmCancel(false); doCancel(); }}
              className="m-press flex-1 rounded-full py-2.5 text-[15px] font-semibold" style={accentSolid()}>Cancel anyway</button>
            <button type="button" onClick={() => setConfirmCancel(false)}
              className="m-press flex-1 rounded-full py-2.5 text-[15px] font-semibold" style={accentChip()}>Keep it</button>
          </div>
        </div>
      )}
      {moving && (
        <div className="m-card px-3 py-3">
          <p className="m-micro mb-2 text-ink-2">You can move a private once. Pick a new day and time.</p>
          <div className="-mx-1 mb-2 flex gap-1.5 overflow-x-auto px-1">
            {moveDays.map((d) => (
              <button key={d} type="button" onClick={() => setMoveDay(d)}
                className="m-press shrink-0 rounded-full px-3 py-1.5 text-[13px] font-semibold"
                style={d === moveDay ? accentSolid() : accentChip()}>
                {new Intl.DateTimeFormat("en-GB", { timeZone, weekday: "short", day: "numeric" }).format(new Date(Date.now() + (d - 1) * 86400e3))}
              </button>
            ))}
          </div>
          <div className="flex flex-wrap gap-2">
            {starts.length === 0 ? <p className="m-sub text-ink-2">No free times that day.</p> : starts.map((s) => (
              <button key={s} type="button" onClick={() => doMove(s)} disabled={pending}
                className="m-press rounded-full px-3.5 py-1.5 text-[14px] font-semibold" style={accentChip()}>
                {fmtClock(s, timeZone, timeFormat)}
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
