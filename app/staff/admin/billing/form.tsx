"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, inputClass } from "@/components/ui";
import { extendTrial, type ExtendState } from "./actions";

function Submit() {
  const { pending } = useFormStatus();
  return (
    <button className="shrink-0 text-[12px] leading-4 text-lime-text underline underline-offset-4"
            disabled={pending}>
      {pending ? "…" : "Extend"}
    </button>
  );
}

/**
 * Days, not a date. An operator extending a trial mid-conversation is thinking
 * "give them another fortnight", not "make it the 14th" — and extend_trial()
 * adds to whatever they have rather than replacing it.
 */
export default function ExtendForm({ studioId }: { studioId: string }) {
  const [state, action] = useFormState<ExtendState, FormData>(extendTrial, null);
  return (
    <form action={action} className="flex shrink-0 items-center gap-2">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <input type="hidden" name="studio_id" value={studioId} />
      <input name="days" type="number" min={1} max={365} defaultValue={14}
             aria-label="Days to extend" className={`${inputClass} w-16 text-[12px]`} />
      <Submit />
    </form>
  );
}
