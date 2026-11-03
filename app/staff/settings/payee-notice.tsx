"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { savePayeeNotice, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Decision 67(b): when a studio's online payments settle to an account under a
 * different legal name, the member checkout tells them before they leave for
 * Xendit. Blank = no line (payments settle to the studio's own account).
 */
export default function PayeeNoticePanel({ value }: { value: string | null }) {
  const [state, action] = useFormState<PlainState, FormData>(savePayeeNotice, null);
  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="block text-[13px] leading-[19px] text-ink">
          <span className="font-medium">Payment processor name shown at checkout</span>
          <span className="block text-[12px] leading-[18px] text-ink-3">
            Leave blank if payments settle to the studio&rsquo;s own account.
          </span>
          <input
            name="payee_notice_name"
            defaultValue={value ?? ""}
            maxLength={120}
            placeholder="DSV Digital Management Corp."
            className="mt-2 w-full rounded border border-line bg-surface px-3 py-2 text-[13px] leading-[19px] text-ink"
          />
        </label>
        <div className="mt-3"><Save /></div>
      </div>
    </form>
  );
}
