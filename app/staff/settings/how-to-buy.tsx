"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveHowToBuy, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Decision 16: most studios sell at the desk, not online. This is the studio's
 * own words on the member /account/plan, under the plan catalogue — so "the
 * plans are here" leads somewhere real. Blank falls back to the app's default.
 */
export default function HowToBuyPanel({ value }: { value: string | null }) {
  const [state, action] = useFormState<PlainState, FormData>(saveHowToBuy, null);
  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="block text-[13px] leading-[19px] text-ink">
          <span className="font-medium">How members buy a plan</span>
          <span className="block text-[12px] leading-[18px] text-ink-3">
            Shown on a member&rsquo;s Plan screen beneath your plans. Leave blank for
            the default, &ldquo;Ask at the desk and we&rsquo;ll set you up.&rdquo;
          </span>
          <textarea
            name="how_to_buy"
            defaultValue={value ?? ""}
            rows={3}
            placeholder="Ask at the desk and we'll set you up."
            className="mt-2 w-full rounded border border-line bg-surface px-3 py-2 text-[13px] leading-[19px] text-ink"
          />
        </label>
        <div className="mt-3"><Save /></div>
      </div>
    </form>
  );
}
