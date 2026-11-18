"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveGift, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Decision 110: gift cards. The public /gift page, the suggested amounts, and
 * the minimum. Off by default. Presets are entered in whole units.
 */
export default function GiftCardsPanel({
  enabled, presetsMajor, minMajor, currency,
}: { enabled: boolean; presetsMajor: number[]; minMajor: number; currency: string }) {
  const [state, action] = useFormState<PlainState, FormData>(saveGift, null);
  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5 text-[13px] leading-[19px] text-ink">
          <input type="checkbox" name="gift_enabled" defaultChecked={enabled} className="mt-0.5" />
          <span>
            <span className="font-medium">Sell gift cards</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              A public page at your member site under /gift where anyone can buy a gift card for
              the studio. Gift credit never expires.
            </span>
          </span>
        </label>

        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          <label className="block text-[13px] text-ink">
            <span className="font-medium">Suggested amounts ({currency})</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">Comma-separated, whole units.</span>
            <input name="gift_presets" defaultValue={presetsMajor.join(", ")} placeholder="1000, 2500, 5000"
              className="mt-1 w-full rounded border border-line bg-surface px-3 py-2 text-[13px] text-ink" />
          </label>
          <label className="block text-[13px] text-ink">
            <span className="font-medium">Smallest amount ({currency})</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">The least a buyer may choose.</span>
            <input name="gift_min" type="number" min={1} step={1} defaultValue={minMajor}
              className="mt-1 w-full rounded border border-line bg-surface px-3 py-2 text-[13px] text-ink" />
          </label>
        </div>

        <div className="mt-3"><Save /></div>
      </div>
    </form>
  );
}
