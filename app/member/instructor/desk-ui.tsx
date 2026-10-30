"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { formatMoney } from "@/lib/plans";
import { fmtClock } from "@/lib/time";
import { addWalkIn, moveBookingHere, recordDeskDropinPaid, sellPlanAtDesk,
         type WalkInResult, type DeskResult } from "./actions";

/** A "class is full" alternative's time, in the STUDIO timezone (task 11). */
function altWhen(start: string, tz: string, timeFormat: "24h" | "12h"): string {
  const day = new Intl.DateTimeFormat("en-GB", {
    timeZone: tz, weekday: "short", day: "numeric", month: "short",
  }).format(new Date(start));
  return `${day} ${fmtClock(start, tz, timeFormat)}`;
}

/** Decision 81a — the desk, from the roster. All amounts via formatMoney. */
export type DeskPlan = { id: string; name: string; price_cents: number };

const METHODS: { v: string; label: string }[] = [
  { v: "gcash", label: "GCash" }, { v: "cash", label: "Cash" }, { v: "card_terminal", label: "Card" },
];

function Reason({ text }: { text: string }) {
  return (
    <p className="mt-2 text-[12px] leading-[17px] text-ink" role="alert"
       style={{ borderLeft: "3px solid var(--coral)", paddingLeft: 8 }}>{text}</p>
  );
}

// ---- Add walk-in -----------------------------------------------------------
export function AddWalkIn({ occurrenceId, currency, tz, timeFormat }: {
  occurrenceId: string; currency: string; tz: string; timeFormat: "24h" | "12h";
}) {
  const router = useRouter();
  const [busy, start] = useTransition();
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [mobile, setMobile] = useState("");
  const [res, setRes] = useState<WalkInResult | null>(null);

  function submit() {
    setRes(null);
    start(async () => {
      const r = await addWalkIn(occurrenceId, name, email, mobile);
      setRes(r);
      if (r.ok) { setName(""); setEmail(""); setMobile(""); router.refresh(); }
    });
  }
  function move(bookingId: string) {
    start(async () => {
      const r = await moveBookingHere(bookingId, occurrenceId);
      if (r.ok) { setRes(null); router.refresh(); }
      else setRes({ ok: false, reason: r.reason });
    });
  }

  const field = "m-tap w-full rounded-xl border border-line-2 bg-surface px-3.5 text-[16px] text-ink outline-none";
  return (
    <div className="m-card mt-5 px-4 py-4">
      <p className="text-[15px] font-semibold leading-5 text-ink">Add a walk-in</p>
      <p className="m-sub mt-0.5 text-ink-3">Books them into this class and checks them in.</p>
      <div className="mt-3 space-y-2">
        <input className={field} placeholder="Name" value={name} onChange={(e) => setName(e.target.value)} />
        <input className={field} placeholder="Email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
        <input className={field} placeholder="Mobile (optional)" value={mobile} onChange={(e) => setMobile(e.target.value)} />
      </div>
      <button disabled={busy || !name || !email} onClick={submit}
              style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
              className="m-action mt-3 w-full rounded-xl text-[15px] font-semibold disabled:opacity-60">
        {busy ? "Adding…" : "Add"}
      </button>

      {res?.ok && (
        <p className="mt-2 text-[13px] leading-5 text-ink-2" role="status">
          Added — {res.seat === "free_first" ? "free first class"
                   : res.seat === "plan" ? "on their plan" : "drop-in"}
          {res.seat === "drop_in" && res.due_cents != null && <> · <span className="num">{formatMoney(res.due_cents, currency)}</span> due at the desk</>}
          {!res.checked_in && res.checkin_reason && <> · not checked in yet ({res.checkin_reason})</>}
        </p>
      )}
      {res && !res.ok && res.reason === "booked elsewhere today" && (
        <div className="mt-2 rounded-lg px-2.5 py-2" style={{ background: "var(--paper)" }}>
          <p className="text-[13px] leading-5 text-ink">
            They&rsquo;re booked into <strong>{res.class_name}</strong> at <span className="num">{res.when}</span> today.
          </p>
          <button disabled={busy} onClick={() => res.booking_id && move(res.booking_id)}
                  className="mt-1.5 rounded-full border border-line-2 bg-surface px-3 py-1.5 text-[13px] font-medium text-ink disabled:opacity-60">
            Move them here
          </button>
        </div>
      )}
      {res && !res.ok && res.reason === "class is full" && (
        <div className="mt-2">
          <Reason text="This class is full. Classes today or tomorrow with a free seat:" />
          <ul className="mt-1.5 space-y-1">
            {(res.alternatives ?? []).map((a) => (
              <li key={a.occurrence_id}>
                <Link href={`/instructor/roster/${a.occurrence_id}`} className="text-[13px] text-ink-2 underline underline-offset-4">
                  {a.name} — {altWhen(a.start, tz, timeFormat)} · {a.seats_left} left
                </Link>
              </li>
            ))}
            {(res.alternatives ?? []).length === 0 && <li className="m-sub text-ink-3">Nothing else with a free seat.</li>}
          </ul>
        </div>
      )}
      {res && !res.ok && res.reason !== "booked elsewhere today" && res.reason !== "class is full" && (
        <Reason text={res.reason} />
      )}
    </div>
  );
}

// ---- Per-row desk payment --------------------------------------------------
export function DeskPay({
  occurrenceId, memberId, bookingId, unpaidDropin, dueCents, currency, plans,
}: {
  occurrenceId: string; memberId: string; bookingId: string;
  unpaidDropin: boolean; dueCents: number | null; currency: string; plans: DeskPlan[];
}) {
  const router = useRouter();
  const [busy, start] = useTransition();
  const [open, setOpen] = useState<"pay" | "sell" | null>(null);
  const [err, setErr] = useState<string | null>(null);

  // Paid-at-desk fields
  const [method, setMethod] = useState("gcash");
  const [amount, setAmount] = useState(dueCents != null ? String(Math.round(dueCents / 100)) : "");
  const [reference, setReference] = useState("");
  // Sold-a-plan fields
  const [planId, setPlanId] = useState(plans[0]?.id ?? "");
  const [sMethod, setSMethod] = useState("gcash");
  const [sRef, setSRef] = useState("");
  const [useToday, setUseToday] = useState(unpaidDropin);

  function done(r: DeskResult) {
    if (r.ok) { setOpen(null); setErr(null); router.refresh(); }
    else setErr(r.reason);
  }
  function pay() {
    setErr(null);
    start(async () => done(await recordDeskDropinPaid(bookingId, occurrenceId, method, Math.round(Number(amount) * 100), reference)));
  }
  function sell() {
    setErr(null);
    start(async () => done(await sellPlanAtDesk(occurrenceId, memberId, planId, sMethod, sRef, unpaidDropin && useToday)));
  }

  const chip = "rounded-full px-2.5 py-1 text-[12px] font-medium";
  const sheetBtn = "m-tap flex-1 rounded-xl border border-line-2 bg-surface text-[13px] font-medium text-ink disabled:opacity-60";
  const field = "m-tap w-full rounded-xl border border-line-2 bg-surface px-3 text-[15px] text-ink outline-none";

  return (
    <div className="mt-2">
      <div className="flex flex-wrap items-center gap-1.5">
        {unpaidDropin && (
          <span className={chip} style={{ background: "var(--amber-tint)", color: "var(--ink)" }}>
            Unpaid{dueCents != null && <> — <span className="num">{formatMoney(dueCents, currency)}</span></>}
          </span>
        )}
        {unpaidDropin && (
          <button onClick={() => setOpen(open === "pay" ? null : "pay")}
                  className="rounded-full border border-line-2 bg-surface px-2.5 py-1 text-[12px] font-medium text-ink">
            Paid at desk
          </button>
        )}
        {plans.length > 0 && (
          <button onClick={() => setOpen(open === "sell" ? null : "sell")}
                  className="rounded-full border border-line-2 bg-surface px-2.5 py-1 text-[12px] font-medium text-ink">
            Sold a plan at desk
          </button>
        )}
      </div>

      {open === "pay" && (
        <div className="mt-2 rounded-lg px-2.5 py-2.5" style={{ background: "var(--paper)" }}>
          <div className="flex gap-1.5">
            {METHODS.map((m) => (
              <button key={m.v} onClick={() => setMethod(m.v)} disabled={busy}
                      className={sheetBtn} aria-pressed={method === m.v}
                      style={method === m.v ? { background: "var(--accent-chip)" } : undefined}>{m.label}</button>
            ))}
          </div>
          <div className="mt-2 flex items-center gap-2">
            <span className="m-sub text-ink-3">{currency}</span>
            <input className={field} inputMode="numeric" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="Amount" />
          </div>
          <input className={`${field} mt-2`} value={reference} onChange={(e) => setReference(e.target.value)} placeholder="Reference (optional)" />
          <button disabled={busy || !amount} onClick={pay}
                  style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
                  className="m-action mt-2 w-full rounded-xl text-[14px] font-semibold disabled:opacity-60">
            {busy ? "Recording…" : "Record payment"}
          </button>
          {err && <Reason text={err} />}
        </div>
      )}

      {open === "sell" && (
        <div className="mt-2 rounded-lg px-2.5 py-2.5" style={{ background: "var(--paper)" }}>
          <select className={field} value={planId} onChange={(e) => setPlanId(e.target.value)} disabled={busy}>
            {plans.map((p) => <option key={p.id} value={p.id}>{p.name} — {formatMoney(p.price_cents, currency)}</option>)}
          </select>
          <div className="mt-2 flex gap-1.5">
            {METHODS.map((m) => (
              <button key={m.v} onClick={() => setSMethod(m.v)} disabled={busy}
                      className={sheetBtn} aria-pressed={sMethod === m.v}
                      style={sMethod === m.v ? { background: "var(--accent-chip)" } : undefined}>{m.label}</button>
            ))}
          </div>
          <input className={`${field} mt-2`} value={sRef} onChange={(e) => setSRef(e.target.value)} placeholder="Reference (optional)" />
          {unpaidDropin && (
            <label className="mt-2 flex items-center gap-2 text-[13px] text-ink">
              <input type="checkbox" checked={useToday} onChange={(e) => setUseToday(e.target.checked)} />
              Use it for today&rsquo;s class
            </label>
          )}
          <button disabled={busy || !planId} onClick={sell}
                  style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
                  className="m-action mt-2 w-full rounded-xl text-[14px] font-semibold disabled:opacity-60">
            {busy ? "Recording…" : "Record sale"}
          </button>
          {err && <Reason text={err} />}
        </div>
      )}
    </div>
  );
}
