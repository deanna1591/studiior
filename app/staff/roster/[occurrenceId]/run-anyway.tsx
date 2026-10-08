"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass, inputClass } from "@/components/ui";
import { forceCommit, type ForceCommitState } from "../actions";

function Go() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Confirming…" : "Run anyway"}</button>;
}

/**
 * Decision 22 — "Run anyway": commit a flex (or high-minimum core) class that is
 * below its minimum so it goes ahead. Behind a one-line reason (the force_commit
 * RPC requires it and audits it). On success the page re-renders and this is
 * replaced by the "Confirmed to run" line, so the control is simply gone.
 */
export default function RunAnyway({ occurrenceId, minimum }: {
  occurrenceId: string; minimum: number;
}) {
  const [state, action] = useFormState<ForceCommitState, FormData>(forceCommit, null);
  const [open, setOpen] = useState(false);

  // On success the server revalidates and the page shows the committed state;
  // nothing to render here.
  if (state?.ok) return null;

  return (
    <div className="mb-5">
      {!open ? (
        <button onClick={() => setOpen(true)}
                className="text-[12px] leading-4 text-ink-3 underline underline-offset-4 hover:text-ink">
          Run this class anyway
        </button>
      ) : (
        <form action={action} className="max-w-xl rounded border border-line bg-surface px-3.5 py-3">
          {state && !state.ok && <Notice kind="error">{state.message}</Notice>}
          <p className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Run anyway.</span> Runs even if it doesn&rsquo;t reach its
            minimum of <span className="num">{minimum}</span>. The instructor is paid at the normal
            headcount rate.
          </p>
          <input type="hidden" name="occurrence_id" value={occurrenceId} />
          <label className="mt-2.5 block text-[12px] leading-4 text-ink-2">
            Why — this goes on the record
            <input name="reason" required autoFocus
                   className={`${inputClass} mt-1`} placeholder="e.g. a private group is coming, numbers are fine" />
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
