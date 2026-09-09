"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice } from "@/components/ui";
import { approveSubmission, requestChanges, type MyState } from "../my/actions";

function Btn({ label, busy, primary }: { label: string; busy: string; primary?: boolean }) {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
            className={primary
              ? "rounded-lg bg-ink px-3 py-1.5 text-[13px] font-medium text-paper disabled:opacity-50"
              : "rounded-lg border border-line-2 px-3 py-1.5 text-[13px] text-ink-2 disabled:opacity-50"}>
      {pending ? busy : label}
    </button>
  );
}

/** Approve, or send it back with a reason. A bare refusal is not a review. */
export default function ReviewControls({ submissionId }: { submissionId: string }) {
  const [approveState, doApprove] = useFormState<MyState, FormData>(approveSubmission, null);
  const [changeState, doChange] = useFormState<MyState, FormData>(requestChanges, null);
  const [open, setOpen] = useState(false);
  const state = changeState ?? approveState;

  return (
    <div className="mt-2.5">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="flex flex-wrap items-center gap-2">
        <form action={doApprove}>
          <input type="hidden" name="submission_id" value={submissionId} />
          <Btn label="Approve" busy="Approving…" primary />
        </form>
        <button type="button" onClick={() => setOpen((v) => !v)}
                className="text-[12.5px] leading-4 text-ink-2 underline underline-offset-4 hover:text-ink">
          Ask for a change
        </button>
      </div>
      {open && (
        <form action={doChange} className="mt-2 flex flex-wrap items-end gap-2">
          <input type="hidden" name="submission_id" value={submissionId} />
          <label className="flex-1 text-[12.5px] leading-4 text-ink-2">
            <span className="mb-1 block">What needs changing</span>
            <input name="note" placeholder="We need you on Wednesday evenings too."
                   className="w-full rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink" />
          </label>
          <Btn label="Send back" busy="Sending…" />
        </form>
      )}
    </div>
  );
}
