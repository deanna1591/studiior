"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, inputClass } from "@/components/ui";
import { checkInByCode, type CodeState } from "../../actions";

function Submit() {
  const { pending } = useFormStatus();
  return (
    <button
      disabled={pending}
      className="inline-flex items-center rounded bg-ink px-3.5 py-2 text-[13px] font-medium leading-[18px] text-paper hover:bg-ink-2 disabled:opacity-45"
    >
      {pending ? "Looking…" : "Check in"}
    </button>
  );
}

/**
 * The other half of the member's QR.
 *
 * Without this the code on the member's phone is a picture nothing can read.
 * There is no camera here yet — the desk types or scans the eight characters
 * into the field, which a hardware barcode scanner does as keystrokes anyway.
 */
export default function CodeCheckIn({ occurrenceId }: { occurrenceId: string }) {
  const [state, action] = useFormState<CodeState, FormData>(checkInByCode, null);
  return (
    <form action={action} className="mb-5">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      <label className="flex flex-wrap items-end gap-2">
        <span className="min-w-[180px] flex-1">
          <span className="mb-1.5 block text-[13px] font-medium leading-[18px] text-ink">
            Member&rsquo;s check-in code
          </span>
          <input
            name="code"
            autoComplete="off"
            placeholder="8 characters from their phone"
            className={`${inputClass} font-mono uppercase tracking-[0.14em]`}
          />
        </span>
        <Submit />
      </label>
    </form>
  );
}
