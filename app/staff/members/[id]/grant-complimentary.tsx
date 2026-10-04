"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { grantComplimentary } from "./membership-actions";

/**
 * Decision 61 — grant an ongoing FREE membership (owner, managers, friends of
 * the studio). Manager-up; the RPC is the boundary. Plan, an optional end date
 * ("until I end it" when blank), and a required reason.
 */
export default function GrantComplimentary({
  memberId, plans,
}: {
  memberId: string;
  plans: { id: string; name: string; type: string }[];
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [planId, setPlanId] = useState(plans[0]?.id ?? "");
  const [endsOn, setEndsOn] = useState("");
  const [reason, setReason] = useState("");
  const [msg, setMsg] = useState<{ text: string; ok: boolean } | null>(null);
  const [pending, start] = useTransition();

  const field =
    "w-full rounded border border-line-2 bg-surface px-2 py-1.5 text-[13px] leading-[18px] text-ink placeholder:text-ink-3 focus:border-lime-text focus:outline-none";

  if (plans.length === 0) return null;

  return (
    <div className="mt-2">
      <button
        type="button"
        onClick={() => { setMsg(null); setOpen((o) => !o); }}
        className="rounded border border-line-2 bg-surface px-2.5 py-1 text-[12px] leading-4 text-ink hover:bg-paper"
      >
        Grant complimentary
      </button>
      {msg && (
        <p className={`mt-2 text-[12px] leading-4 ${msg.ok ? "text-ink-2" : ""}`}
           style={msg.ok ? undefined : { color: "var(--coral)" }}>
          {msg.text}
        </p>
      )}
      {open && (
        <div className="mt-2 space-y-2 rounded-lg border border-line-2 bg-paper p-2.5">
          <label className="block">
            <span className="text-[11px] leading-4 text-ink-3">Plan</span>
            <select value={planId} onChange={(e) => setPlanId(e.target.value)} className={`${field} mt-1`}>
              {plans.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select>
          </label>
          <label className="block">
            <span className="text-[11px] leading-4 text-ink-3">Until (leave blank for no end date)</span>
            <input type="date" value={endsOn} onChange={(e) => setEndsOn(e.target.value)} className={`${field} num mt-1`} />
          </label>
          <label className="block">
            <span className="text-[11px] leading-4 text-ink-3">Reason</span>
            <input value={reason} onChange={(e) => setReason(e.target.value)}
                   placeholder="owner, studio manager, ambassador…" className={`${field} mt-1`} />
          </label>
          <button
            type="button"
            disabled={pending || !planId || !reason.trim()}
            onClick={() => {
              setMsg(null);
              start(async () => {
                const r = await grantComplimentary(memberId, planId, endsOn || null, reason);
                if ("ok" in r && r.ok) {
                  setMsg({ text: r.sentence, ok: true });
                  setOpen(false);
                  start(() => router.refresh());
                } else {
                  setMsg({ text: "error" in r ? r.error : "That could not be done.", ok: false });
                }
              });
            }}
            className="inline-flex items-center rounded bg-ink px-3 py-1.5 text-[12px] font-medium leading-4 text-paper hover:bg-ink-2 disabled:opacity-45"
          >
            {pending ? "…" : "Grant"}
          </button>
        </div>
      )}
    </div>
  );
}
