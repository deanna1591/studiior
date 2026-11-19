"use client";

import { useEffect, useState, useTransition } from "react";
import { fmtClock } from "@/lib/clock";
import { formatMoney } from "@/lib/format-money";
import {
  staffPrivateOptions, staffPrivateSlots, staffBookPrivate, type StaffPrivateOptions,
} from "@/app/staff/members/private-actions";

const input = "w-full rounded border border-line bg-surface px-3 py-2 text-[13px] text-ink";

/** The studio-local midnight of a YYYY-MM-DD date in a zone, as an instant. */
function zoneMidnight(ymd: string, timeZone: string): Date {
  const [y, m, d] = ymd.split("-").map(Number);
  const guess = Date.UTC(y, m - 1, d);
  const p = new Intl.DateTimeFormat("en-US", { timeZone, hour12: false, year: "numeric", month: "2-digit",
    day: "2-digit", hour: "2-digit", minute: "2-digit" }).formatToParts(new Date(guess));
  const g = (k: string) => Number(p.find((x) => x.type === k)?.value);
  return new Date(guess - (Date.UTC(g("year"), g("month") - 1, g("day"), g("hour") % 24, g("minute")) - guess));
}

/**
 * Decision 116: staff book a private for a member from the profile and record
 * the desk payment (or spend the member's 1:1 pack credit). Confirmed at once.
 */
export function BookPrivateFromProfile({ memberId }: { memberId: string }) {
  const [open, setOpen] = useState(false);
  const [opts, setOpts] = useState<StaffPrivateOptions | null>(null);
  const [typeId, setTypeId] = useState("");
  const [coachId, setCoachId] = useState<string>("");
  const [date, setDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [starts, setStarts] = useState<string[]>([]);
  const [at, setAt] = useState("");
  const [comps, setComps] = useState<{ name: string; email: string }[]>([]);
  const [method, setMethod] = useState("cash");
  const [ref, setRef] = useState("");
  const [msg, setMsg] = useState<{ ok: boolean; message: string } | null>(null);
  const [pending, start] = useTransition();

  useEffect(() => {
    if (!open || opts) return;
    staffPrivateOptions().then((o) => { setOpts(o); if (o?.types[0]) setTypeId(o.types[0].id); });
  }, [open, opts]);
  const t = opts?.types.find((x) => x.id === typeId);
  useEffect(() => { setComps(Array.from({ length: Math.max(0, (t?.people ?? 1) - 1) }, () => ({ name: "", email: "" }))); }, [t?.people]);
  useEffect(() => {
    if (!opts || !typeId) return;
    const from = zoneMidnight(date, opts.timeZone);
    setAt("");
    staffPrivateSlots(typeId, coachId || null, from.toISOString(), new Date(from.getTime() + 86400e3).toISOString())
      .then((r) => setStarts(r.starts));
  }, [opts, typeId, coachId, date]);

  if (!open) {
    return (
      <button type="button" onClick={() => setOpen(true)}
        className="rounded border border-line bg-surface px-3 py-1.5 text-[13px] font-medium text-ink">
        Book a private
      </button>
    );
  }
  if (opts && !opts.enabled) {
    return <p className="text-[13px] text-ink-2">Private sessions are off. Turn them on in Settings, Memberships &amp; payments.</p>;
  }
  return (
    <div className="w-full max-w-xl rounded border border-line bg-surface px-3.5 py-3">
      <p className="text-[13px] font-medium text-ink">Book a private</p>
      {!opts ? <p className="mt-2 text-[13px] text-ink-2">Loading…</p> : (
        <div className="mt-2 grid gap-2 sm:grid-cols-3">
          <label className="text-[12px] text-ink">Session
            <select value={typeId} onChange={(e) => setTypeId(e.target.value)} className={input}>
              {opts.types.map((x) => <option key={x.id} value={x.id}>{x.name} · {formatMoney(x.price_cents, opts.currency)}</option>)}
            </select>
          </label>
          <label className="text-[12px] text-ink">Coach
            <select value={coachId} onChange={(e) => setCoachId(e.target.value)} className={input}>
              <option value="">Any coach</option>
              {opts.coaches.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
          </label>
          <label className="text-[12px] text-ink">Day
            <input type="date" value={date} onChange={(e) => setDate(e.target.value)} className={input} />
          </label>
          <div className="sm:col-span-3">
            <p className="text-[12px] text-ink">Free times</p>
            <div className="mt-1 flex flex-wrap gap-1.5">
              {starts.length === 0 ? <span className="text-[12px] text-ink-2">No free times that day.</span> : starts.map((s) => (
                <button key={s} type="button" onClick={() => setAt(s)}
                  className="rounded border px-2 py-1 text-[12px]"
                  style={at === s ? { background: "var(--ink)", color: "var(--surface)", borderColor: "var(--ink)" } : { borderColor: "var(--line-2)", color: "var(--ink)" }}>
                  {fmtClock(s, opts.timeZone, "24h")}
                </button>
              ))}
            </div>
          </div>
          {comps.map((c, i) => (
            <div key={i} className="grid grid-cols-2 gap-2 sm:col-span-3">
              <input placeholder="Companion name" value={c.name} onChange={(e) => setComps(comps.map((x, j) => j === i ? { ...x, name: e.target.value } : x))} className={input} />
              <input placeholder="Companion email" value={c.email} onChange={(e) => setComps(comps.map((x, j) => j === i ? { ...x, email: e.target.value } : x))} className={input} />
            </div>
          ))}
          <label className="text-[12px] text-ink">Paid with
            <select value={method} onChange={(e) => setMethod(e.target.value)} className={input}>
              <option value="cash">Cash</option><option value="gcash">GCash</option>
              <option value="card_terminal">Card (terminal)</option><option value="bank_transfer">Bank transfer</option>
              <option value="other">Other</option>
              {t?.people === 1 && <option value="pack">Their private pack credit</option>}
            </select>
          </label>
          {method !== "pack" && (
            <label className="text-[12px] text-ink sm:col-span-2">Reference (optional)
              <input value={ref} onChange={(e) => setRef(e.target.value)} className={input} />
            </label>
          )}
          <div className="flex items-center gap-3 sm:col-span-3">
            <button type="button" disabled={pending || !at}
              onClick={() => start(async () => setMsg(await staffBookPrivate({ memberId, typeId, coachId: coachId || null, startsAt: at, companions: comps, method, reference: ref })))}
              className="rounded px-3 py-1.5 text-[13px] font-semibold disabled:opacity-60"
              style={{ background: "var(--ink)", color: "var(--surface)" }}>
              {pending ? "Booking…" : "Book and confirm"}
            </button>
            <button type="button" onClick={() => setOpen(false)} className="text-[13px] text-ink-2 underline">Close</button>
          </div>
          {msg && <p className="text-[13px] text-ink sm:col-span-3">{msg.message}</p>}
        </div>
      )}
    </div>
  );
}
