"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice } from "@/components/ui";
import { reopenSubmission, type MyState } from "../my/actions";

function Btn({ label, busy }: { label: string; busy: string }) {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
            className="rounded-lg border border-line-2 px-3 py-1.5 text-[13px] text-ink-2 disabled:opacity-50">
      {pending ? busy : label}
    </button>
  );
}

/**
 * Decision 96: reopen an approved (or submitted) month before the cut-off so the
 * instructor can edit it. One button, an optional note. The button is only
 * rendered while the studio-local date is on or before the due day — after that
 * the page drops it and the database refuses as a belt.
 */
export default function ReopenControls({ submissionId }: { submissionId: string }) {
  const [state, doReopen] = useFormState<MyState, FormData>(reopenSubmission, null);
  const [open, setOpen] = useState(false);

  return (
    <div className="mt-2.5">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <form action={doReopen} className="flex flex-wrap items-end gap-2">
        <input type="hidden" name="submission_id" value={submissionId} />
        {open && (
          <label className="flex-1 text-[12.5px] leading-4 text-ink-2">
            <span className="mb-1 block">What to change (optional)</span>
            <input name="note" placeholder="Reopened so you can make changes."
                   className="w-full rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink" />
          </label>
        )}
        <Btn label="Reopen for editing" busy="Reopening…" />
        {!open && (
          <button type="button" onClick={() => setOpen(true)}
                  className="text-[12.5px] leading-4 text-ink-2 underline underline-offset-4 hover:text-ink">
            Add a note
          </button>
        )}
      </form>
    </div>
  );
}
