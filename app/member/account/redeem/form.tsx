"use client";

import { useState, useTransition } from "react";
import { accentSolid } from "@/lib/accent-pair";
import { redeemGift, type RedeemState } from "./actions";

export default function RedeemForm() {
  const [pending, start] = useTransition();
  const [state, setState] = useState<RedeemState>(null);

  function submit(fd: FormData) {
    start(async () => setState(await redeemGift(null, fd)));
  }

  if (state?.ok) {
    return (
      <div className="m-card p-4" style={{ background: "var(--accent-chip)" }}>
        <p className="m-name text-ink">Added to your account.</p>
        <p className="m-sub mt-1 text-ink-2">
          {state.amount ? `${state.amount} of gift credit is yours` : "Your gift credit is yours"} — it
          comes off your next checkout before any payment.
        </p>
      </div>
    );
  }

  return (
    <form action={submit} className="space-y-3">
      <input name="code" autoCapitalize="characters" autoComplete="off" spellCheck={false}
        placeholder="e.g. REFO-ABCD-2345"
        className="w-full rounded-xl border border-line bg-surface px-3.5 py-3 text-[16px] tracking-wide text-ink" />
      {state && !state.ok && (
        <p className="rounded-lg px-3 py-2 text-[13px] leading-[19px]"
           style={{ background: "var(--coral-tint)", color: "var(--ink)" }}>{state.message}</p>
      )}
      <button type="submit" disabled={pending}
        className="m-press w-full rounded-full py-3 text-center text-[15px] font-semibold disabled:opacity-60"
        style={accentSolid()}>
        {pending ? "Redeeming…" : "Redeem"}
      </button>
    </form>
  );
}
