"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { fromCents, toCents } from "@/lib/plans";
import {
  endMembership, freezeMembership, unfreezeMembership,
  extendMembership, markMembershipPaid, refundMembership,
  type MembershipActionResult,
} from "./membership-actions";

/**
 * Decision 49 — the membership actions, inline, manager-up.
 *
 * On the member screen (`compact` off) the five actions are a row of quiet
 * toggles under the live membership; on a Sales row (`compact` on) they fold
 * into one "Manage" disclosure so the table stays a table. Each opens a small
 * form and shows the SQL's own sentence, or its refusal, inline — the pattern
 * the roster's Cancel uses. A success refreshes the route so the block redraws.
 */

const METHODS: [string, string][] = [
  ["cash", "Cash"],
  ["bank_transfer", "Bank transfer"],
  ["card_terminal", "Card (terminal)"],
  ["gcash", "GCash"],
  ["other", "Other"],
];

type Key = "end" | "freeze" | "unfreeze" | "extend" | "paid" | "refund";

function fmtDate(value: string | null | undefined): string | null {
  if (!value) return null;
  // Date-only strings have no zone; anchor at noon so a display never slips a day.
  return new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric" })
    .format(new Date(`${value}T12:00:00`));
}

export default function MembershipActions({
  membershipId, frozen, frozenUntil, priceCents, currency, expiresOn, today, compact,
  complimentary = false,
}: {
  membershipId: string;
  frozen: boolean;
  frozenUntil?: string | null;
  priceCents: number;
  currency: string;
  expiresOn?: string | null;
  today: string;
  compact?: boolean;
  complimentary?: boolean;
}) {
  const router = useRouter();
  const [open, setOpen] = useState<Key | null>(null);
  const [msg, setMsg] = useState<{ text: string; ok: boolean } | null>(null);
  const [pending, start] = useTransition();

  // One set of fields; reset when a panel opens.
  const [keepCredits, setKeepCredits] = useState(false);
  const [endReason, setEndReason] = useState("");
  const [until, setUntil] = useState("");
  const [newExpiry, setNewExpiry] = useState(expiresOn ?? "");
  const [extendReason, setExtendReason] = useState("");
  const [paidAmount, setPaidAmount] = useState(fromCents(priceCents));
  const [paidMethod, setPaidMethod] = useState("cash");
  const [refundAmount, setRefundAmount] = useState("");
  const [refundReason, setRefundReason] = useState("");
  const [refundEnd, setRefundEnd] = useState(false);

  const toggle = (k: Key) => {
    setMsg(null);
    setOpen((cur) => (cur === k ? null : k));
  };

  const run = (fn: () => Promise<MembershipActionResult>) => {
    setMsg(null);
    start(async () => {
      const r = await fn();
      if ("ok" in r && r.ok) {
        setMsg({ text: r.sentence, ok: true });
        setOpen(null);
        start(() => router.refresh());
      } else {
        setMsg({ text: "error" in r ? r.error : "That could not be done.", ok: false });
      }
    });
  };

  const tabBtn =
    "rounded border border-line-2 bg-surface px-2.5 py-1 text-[12px] leading-4 text-ink hover:bg-paper";
  const tabBtnActive =
    "rounded border border-ink bg-paper px-2.5 py-1 text-[12px] leading-4 text-ink";
  const field =
    "w-full rounded border border-line-2 bg-surface px-2 py-1.5 text-[13px] leading-[18px] text-ink placeholder:text-ink-3 focus:border-lime-text focus:outline-none";
  const go =
    "inline-flex items-center rounded bg-ink px-3 py-1.5 text-[12px] font-medium leading-4 text-paper hover:bg-ink-2 disabled:opacity-45";
  const destructive =
    "inline-flex items-center rounded border bg-coral-tint px-3 py-1.5 text-[12px] font-medium leading-4 text-ink disabled:opacity-45";

  const TB = ({ k, children }: { k: Key; children: React.ReactNode }) => (
    <button type="button" onClick={() => toggle(k)} className={open === k ? tabBtnActive : tabBtn}>
      {children}
    </button>
  );

  const body = (
    <>
      <div className="flex flex-wrap items-center gap-1.5">
        <TB k="end">End</TB>
        {frozen ? <TB k="unfreeze">Unfreeze</TB> : <TB k="freeze">Freeze</TB>}
        <TB k="extend">Extend</TB>
        {/* Decision 61: a complimentary membership is not a sale — nothing to
            pay or refund. */}
        {!complimentary && <TB k="paid">Mark paid</TB>}
        {!complimentary && <TB k="refund">Record refund</TB>}
      </div>

      {open === "end" && (
        <div className="mt-2 rounded-lg border border-line bg-surface p-2.5">
          <label className="flex items-center gap-1.5 text-[13px] text-ink">
            <input type="checkbox" checked={keepCredits} onChange={(e) => setKeepCredits(e.target.checked)} />
            Keep remaining credits
          </label>
          <input value={endReason} onChange={(e) => setEndReason(e.target.value)}
                 placeholder="Reason (optional)" className={`${field} mt-2`} />
          <button onClick={() => run(() => endMembership(membershipId, keepCredits, endReason))}
                  disabled={pending} className={`${destructive} mt-2`} style={{ borderColor: "var(--coral)" }}>
            {pending ? "…" : "End membership"}
          </button>
        </div>
      )}

      {open === "freeze" && (
        <div className="mt-2 rounded-lg border border-line bg-surface p-2.5">
          <label className="block text-[12px] leading-4 text-ink-2">
            Paused until
            <input type="date" value={until} min={today} onChange={(e) => setUntil(e.target.value)}
                   className={`${field} mt-1`} />
          </label>
          <button onClick={() => run(() => freezeMembership(membershipId, until))}
                  disabled={pending || !until} className={`${go} mt-2`}>
            {pending ? "…" : "Freeze"}
          </button>
        </div>
      )}

      {open === "unfreeze" && (
        <div className="mt-2 rounded-lg border border-line bg-surface p-2.5">
          <p className="text-[12px] leading-4 text-ink-2">
            {fmtDate(frozenUntil) ? `Paused until ${fmtDate(frozenUntil)}.` : "Currently paused."}
            {" "}Unpausing moves the expiry on by the days it was paused.
          </p>
          <button onClick={() => run(() => unfreezeMembership(membershipId))}
                  disabled={pending} className={`${go} mt-2`}>
            {pending ? "…" : "Unfreeze"}
          </button>
        </div>
      )}

      {open === "extend" && (
        <div className="mt-2 rounded-lg border border-line bg-surface p-2.5">
          <label className="block text-[12px] leading-4 text-ink-2">
            New expiry
            <input type="date" value={newExpiry} min={today} onChange={(e) => setNewExpiry(e.target.value)}
                   className={`${field} mt-1`} />
          </label>
          <input value={extendReason} onChange={(e) => setExtendReason(e.target.value)}
                 placeholder="Reason (required)" className={`${field} mt-2`} />
          <button onClick={() => run(() => extendMembership(membershipId, newExpiry, extendReason))}
                  disabled={pending || !newExpiry || !extendReason.trim()} className={`${go} mt-2`}>
            {pending ? "…" : "Extend"}
          </button>
        </div>
      )}

      {open === "paid" && (
        <div className="mt-2 rounded-lg border border-line bg-surface p-2.5">
          <div className="flex flex-wrap items-end gap-2">
            <label className="block text-[12px] leading-4 text-ink-2">
              Amount
              <input value={paidAmount} onChange={(e) => setPaidAmount(e.target.value)} inputMode="decimal"
                     className={`${field} num mt-1 w-28`} />
            </label>
            <label className="block text-[12px] leading-4 text-ink-2">
              Method
              <select value={paidMethod} onChange={(e) => setPaidMethod(e.target.value)} className={`${field} mt-1`}>
                {METHODS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
              </select>
            </label>
          </div>
          <button
            onClick={() => {
              const cents = toCents(paidAmount);
              if (cents === null || cents <= 0) { setMsg({ text: "Enter the amount paid.", ok: false }); return; }
              run(() => markMembershipPaid(membershipId, cents, paidMethod));
            }}
            disabled={pending} className={`${go} mt-2`}>
            {pending ? "…" : "Mark paid"}
          </button>
        </div>
      )}

      {open === "refund" && (
        <div className="mt-2 rounded-lg border border-line bg-surface p-2.5">
          <label className="block text-[12px] leading-4 text-ink-2">
            Amount <span className="text-ink-3">({currency})</span>
            <input value={refundAmount} onChange={(e) => setRefundAmount(e.target.value)} inputMode="decimal"
                   placeholder="Full refund" className={`${field} num mt-1 w-32`} />
          </label>
          <input value={refundReason} onChange={(e) => setRefundReason(e.target.value)}
                 placeholder="Reason" className={`${field} mt-2`} />
          <label className="mt-2 flex items-center gap-1.5 text-[13px] text-ink">
            <input type="checkbox" checked={refundEnd} onChange={(e) => setRefundEnd(e.target.checked)} />
            Also end the membership
          </label>
          <p className="mt-1.5 text-[11px] leading-4 text-ink-3">
            Refunds are recorded here. A Xendit refund is done in the Xendit
            dashboard, then recorded.
          </p>
          <button
            onClick={() => {
              const trimmed = refundAmount.trim();
              let cents: number | null = null;
              if (trimmed !== "") {
                cents = toCents(trimmed);
                if (cents === null || cents <= 0) { setMsg({ text: "Enter a valid amount, or leave it blank for a full refund.", ok: false }); return; }
              }
              run(() => refundMembership(membershipId, cents, refundReason, refundEnd));
            }}
            disabled={pending} className={`${destructive} mt-2`} style={{ borderColor: "var(--coral)" }}>
            {pending ? "…" : "Record refund"}
          </button>
        </div>
      )}

      {msg && (
        <p className={`mt-2 text-[12.5px] leading-[18px] ${msg.ok ? "text-ink-2" : "text-ink"}`}>
          {msg.text}
        </p>
      )}
    </>
  );

  if (compact) {
    return (
      <details className="group">
        <summary className="cursor-pointer list-none text-[12px] leading-4 text-lime-text underline underline-offset-4 hover:text-lime-text2">
          Manage
        </summary>
        <div className="mt-2 w-[260px] max-w-[80vw]">{body}</div>
      </details>
    );
  }

  return (
    <div className="mt-3 border-t border-line pt-3">
      <h3 className="section-label mb-2 text-ink-3">Manage this membership</h3>
      {body}
    </div>
  );
}
