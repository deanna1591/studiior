"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { setComplimentary, clearComplimentary, type CompState } from "./actions";

function Btn({ label, className }: { label: string; className: string }) {
  const { pending } = useFormStatus();
  return <button className={className} disabled={pending}>{pending ? "…" : label}</button>;
}

/**
 * Decision 53 — mark a studio complimentary (note required) or stop it. Operator
 * control on /admin/billing.
 */
export default function CompForm({ studioId, isComplimentary }: {
  studioId: string; isComplimentary: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [setState, setAction] = useFormState<CompState, FormData>(setComplimentary, null);
  const [clearState, clearAction] = useFormState<CompState, FormData>(clearComplimentary, null);

  if (isComplimentary) {
    return (
      <form action={clearAction} className="flex flex-col items-end gap-1">
        <input type="hidden" name="studio_id" value={studioId} />
        <Btn label="Stop complimentary"
             className="rounded border border-line-2 bg-surface px-2.5 py-1 text-[12px] text-ink-2 disabled:opacity-60" />
        {clearState && !clearState.ok && <span className="text-[11px] text-coral-deep">{clearState.message}</span>}
      </form>
    );
  }

  if (!open) {
    return (
      <button type="button" onClick={() => setOpen(true)}
              className="rounded border border-line-2 bg-surface px-2.5 py-1 text-[12px] text-ink-2">
        Make complimentary
      </button>
    );
  }

  return (
    <form action={setAction} className="flex flex-col items-end gap-1">
      <input type="hidden" name="studio_id" value={studioId} />
      <div className="flex items-center gap-1.5">
        <input name="note" required placeholder="Why? (note)"
               className="w-44 rounded border border-line-2 bg-paper px-2 py-1 text-[12px] text-ink" />
        <Btn label="Confirm"
             className="rounded bg-ink px-2.5 py-1 text-[12px] text-paper disabled:opacity-60" />
        <button type="button" onClick={() => setOpen(false)}
                className="text-[11px] text-ink-3 hover:text-ink">Cancel</button>
      </div>
      {setState && !setState.ok && <span className="text-[11px] text-coral-deep">{setState.message}</span>}
    </form>
  );
}
