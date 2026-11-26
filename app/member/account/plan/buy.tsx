"use client";

import { useEffect } from "react";
import { accentSolid } from "@/lib/accent-pair";
import { useFormState, useFormStatus } from "react-dom";
import { buyPlan, type BuyState } from "./actions";
import CodeBox from "@/components/code-box";
import { previewMemberCode } from "@/app/member/code-actions";

function BuyButton() {
  const { pending } = useFormStatus();
  return (
    <button
      disabled={pending}
      style={accentSolid()}
      className="m-tap m-press shrink-0 rounded-full px-4 text-[13px] font-bold disabled:opacity-60"
    >
      {pending ? "Opening…" : "Buy"}
    </button>
  );
}

/** Decision 40: Buy a one-time plan online. On success we get the Xendit hosted
 *  checkout URL and navigate to it (full external navigation). */
export default function BuyPlan({ planId, returnTo, currency = "PHP" }: { planId: string; returnTo?: string | null; currency?: string }) {
  const [state, action] = useFormState<BuyState, FormData>(buyPlan, null);
  useEffect(() => {
    if (state?.ok && state.url) window.location.assign(state.url);
  }, [state]);
  return (
    <form action={action}>
      <input type="hidden" name="plan_id" value={planId} />
      {/* Decision 73b: carry the class to return to after a successful buy. */}
      {returnTo && <input type="hidden" name="return" value={returnTo} />}
      <div className="flex flex-col items-end gap-2">
        <BuyButton />
        {/* Decision 120: a discount code, checked at once; Buy carries it. */}
        <div className="w-full max-w-[280px] text-right">
          <CodeBox compact currency={currency}
                   preview={(code) => previewMemberCode({ code, planId })} />
        </div>
      </div>
      {state && !state.ok && state.message && (
        <p className="m-sub mt-1 font-semibold text-ink" role="alert">{state.message}</p>
      )}
    </form>
  );
}
