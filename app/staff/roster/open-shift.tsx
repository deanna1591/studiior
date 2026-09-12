"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass, inputClass } from "@/components/ui";
import { openShift, type OpenShiftState } from "./actions";

function Go() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Opening…" : "Open this shift"}</button>;
}

/**
 * Take the instructor off, from the class itself. Behind a confirm-style
 * disclosure rather than a bare button on the roster, because it emails the
 * instructor — it should take a deliberate second click and a reason.
 */
export default function OpenShift({ occurrenceId, instructorName }: {
  occurrenceId: string; instructorName: string;
}) {
  const [state, action] = useFormState<OpenShiftState, FormData>(openShift, null);
  const [open, setOpen] = useState(false);

  if (state?.ok) return <Notice kind="ok">{state.message}</Notice>;

  return (
    <div className="mb-5">
      {!open ? (
        <button onClick={() => setOpen(true)}
                className="text-[12px] leading-4 text-ink-3 underline underline-offset-4 hover:text-ink">
          Take {instructorName} off and open this shift
        </button>
      ) : (
        <form action={action} className="max-w-xl rounded border border-line bg-surface px-3.5 py-3">
          {state && !state.ok && <Notice kind="error">{state.message}</Notice>}
          <p className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Open this shift.</span> {instructorName} comes off it and
            is told why; the class stays bookable and where it is; qualified instructors are emailed
            that it is going.
          </p>
          <input type="hidden" name="occurrence_id" value={occurrenceId} />
          <label className="mt-2.5 block text-[12px] leading-4 text-ink-2">
            Why — {instructorName} sees this
            <input name="reason" required autoFocus
                   className={`${inputClass} mt-1`} placeholder="e.g. they asked for the morning off" />
          </label>
          <div className="mt-3 flex items-center gap-3">
            <Go />
            <button type="button" onClick={() => setOpen(false)}
                    className="text-[12px] text-ink-3 underline underline-offset-4">Cancel</button>
          </div>
        </form>
      )}
    </div>
  );
}
