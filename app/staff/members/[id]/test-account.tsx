"use client";

import { useState, useTransition } from "react";
import { setTestAccount } from "./test-account-actions";

/**
 * Decision 97 (b): a test account is left out of campaigns, the convert, keep
 * and retention sequences, rescue emails, audience and dashboard counts and the
 * daily check. Its own booking and purchase emails still send.
 */
export default function TestAccount({ memberId, on }: { memberId: string; on: boolean }) {
  const [cur, setCur] = useState(on);
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  return (
    <div className="mt-4 rounded border border-line bg-surface px-4 py-3" data-testid="test-account">
      <label className="flex items-start gap-2.5">
        <input type="checkbox" className="mt-1" checked={cur} disabled={pending}
          onChange={(e) => {
            const next = e.target.checked;
            start(async () => {
              setErr(null);
              const r = await setTestAccount(memberId, next);
              if ("error" in r) setErr(r.error); else setCur(next);
            });
          }} />
        <span className="text-[13px] leading-[19px] text-ink">
          <span className="font-medium">Test account</span>
          <span className="block text-[12px] leading-[18px] text-ink-3">
            Left out of campaigns, sequences, rescue emails and the studio&apos;s counts. Booking and
            purchase emails still send, so you can test the flows.
          </span>
        </span>
      </label>
      {err && <p className="mt-1.5 text-[12px] text-coral">{err}</p>}
    </div>
  );
}
