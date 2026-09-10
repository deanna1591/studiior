"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { guarantee, type FlexState } from "./actions";

function Go() {
  const { pending } = useFormStatus();
  return (
    <button className={buttonQuietClass} disabled={pending}>
      {pending ? "Setting…" : "Run it anyway"}
    </button>
  );
}

export default function Guarantee({ occurrenceId }: { occurrenceId: string }) {
  const [state, action] = useFormState<FlexState, FormData>(guarantee, null);
  return (
    <div>
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <form action={action}>
        <input type="hidden" name="occurrence_id" value={occurrenceId} />
        <Go />
      </form>
    </div>
  );
}
