"use client";

import { useState, useTransition } from "react";
import { voidGift, resendGift, type GiftAdminState } from "./actions";

/**
 * Decision 110: per-card Resend (re-queues the recipient email) and Void (with a
 * reason), on an active card. Manager-up — the SQL refuses otherwise.
 */
export default function GiftRowActions({ id }: { id: string }) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<string | null>(null);
  const [voiding, setVoiding] = useState(false);
  const [reason, setReason] = useState("");

  function run(fn: (p: GiftAdminState, fd: FormData) => Promise<GiftAdminState>, extra?: Record<string, string>) {
    const fd = new FormData();
    fd.set("gift_card_id", id);
    if (extra) for (const [k, v] of Object.entries(extra)) fd.set(k, v);
    start(async () => {
      const r = await fn(null, fd);
      setMsg(r?.message ?? null);
      if (r?.ok) setVoiding(false);
    });
  }

  return (
    <div className="flex flex-col items-end gap-1">
      <div className="flex gap-2">
        <button type="button" disabled={pending} onClick={() => run(resendGift)}
          className="rounded-full border border-line px-3 py-1 text-[12px] font-medium disabled:opacity-50">
          Resend
        </button>
        <button type="button" disabled={pending} onClick={() => setVoiding((v) => !v)}
          className="rounded-full border border-line px-3 py-1 text-[12px] font-medium"
          style={{ color: "var(--coral-deep)" }}>
          Void
        </button>
      </div>
      {voiding && (
        <div className="flex items-center gap-1.5">
          <input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Reason"
            className="rounded-md border border-line px-2 py-1 text-[12px]" />
          <button type="button" disabled={pending || !reason.trim()}
            onClick={() => run(voidGift, { reason })}
            className="rounded-full px-3 py-1 text-[12px] font-semibold disabled:opacity-50"
            style={{ background: "var(--coral-deep)", color: "#fff" }}>
            Confirm void
          </button>
        </div>
      )}
      {msg && <span className="text-[12px] text-ink-3">{msg}</span>}
    </div>
  );
}
