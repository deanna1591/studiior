"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveConversion, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

const field = "rounded border border-line-2 bg-surface px-3 py-2 text-[14px] text-ink outline-none";

/**
 * The conversion bonus (Decision 22 / migration 083). Paid ONCE per member ever,
 * to the instructor of that member's first-ever class, when they buy a qualifying
 * plan within the window. Which plans qualify is set per plan (counts toward the
 * conversion bonus) — shown only while this is on. Off leaves no trace.
 */
export default function ConversionPanel(
  { enabled, amountCents, windowDays, currency }:
  { enabled: boolean; amountCents: number; windowDays: number; currency: string },
) {
  const [state, action] = useFormState<PlainState, FormData>(saveConversion, null);
  const [on, setOn] = useState(enabled);

  return (
    <form action={action} className="max-w-xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface p-4">
        <label className="flex items-center gap-2">
          <input type="checkbox" name="conversion_bonus_enabled" defaultChecked={enabled}
                 onChange={(e) => setOn(e.target.checked)} />
          <span className="text-[13px] font-medium text-ink">Pay a conversion bonus</span>
        </label>
        <p className="mt-1 text-[12px] leading-[18px] text-ink-3">
          When a member buys a qualifying plan soon after their first class, the instructor
          who taught that first class earns a bonus — once per member, ever.
        </p>

        {on && (
          <>
            <label className="mt-3 block">
              <span className="mb-1 block text-[13px] font-medium text-ink">Bonus amount ({currency})</span>
              <input name="conversion_bonus_amount" type="number" min={0} step="1"
                     defaultValue={Math.round(amountCents / 100)} className={`${field} w-32`} />
            </label>
            <label className="mt-3 block">
              <span className="mb-1 block text-[13px] font-medium text-ink">Window (days)</span>
              <input name="conversion_window_days" type="number" min={1} max={365}
                     defaultValue={windowDays} className={`${field} w-24`} />
              <span className="mt-1 block text-[12px] text-ink-3">
                The member must buy within this many days of their first class.
              </span>
            </label>
            <div className="mt-3 rounded bg-accent-chip px-3 py-2">
              <span className="text-[13px] font-medium text-ink">Attributed to: the first class</span>
              <p className="mt-0.5 text-[12px] leading-[18px] text-ink-2">
                Always the instructor of the member’s first-ever class, never the most recent —
                last-class attribution would reward whoever happened to teach the day a card cleared.
                This cannot be changed.
              </p>
            </div>
            <p className="mt-3 text-[12px] leading-[18px] text-ink-3">
              Set which plans qualify on each plan’s own screen (“counts toward the conversion bonus”).
            </p>
          </>
        )}

        <div className="mt-4"><Save /></div>
      </div>
    </form>
  );
}
