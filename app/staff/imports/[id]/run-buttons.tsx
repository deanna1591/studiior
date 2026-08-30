"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonClass } from "@/components/ui";
import { commitImport, rollbackImport, type ImportState } from "../actions";

function Submit({ label, busy, danger }: { label: string; busy: string; danger?: boolean }) {
  const { pending } = useFormStatus();
  return (
    <button
      disabled={pending}
      className={danger
        ? "rounded border border-rose-300 bg-white px-3 py-1.5 text-sm text-rose-700 hover:bg-rose-50 disabled:opacity-50"
        : buttonClass}
    >
      {pending ? busy : label}
    </button>
  );
}

export function CommitButton({ id, okCount }: { id: string; okCount: number }) {
  const [state, action] = useFormState<ImportState, FormData>(commitImport, null);
  return (
    <form action={action} className="space-y-2">
      {state && <Notice kind="error">{state.error}</Notice>}
      <input type="hidden" name="id" value={id} />
      <Submit label={`Import ${okCount} row${okCount === 1 ? "" : "s"}`} busy="Importing…" />
    </form>
  );
}

/**
 * Rollback asks first, in words, and says what it will remove.
 *
 * It is one action and it is exact — only rows this import created — but it is
 * still a deletion of member data, and a button that does that on a single
 * click next to "Import" is a button someone will hit by accident.
 */
export function RollbackButton({ id, created, noun }: { id: string; created: number; noun: string }) {
  const [state, action] = useFormState<ImportState, FormData>(rollbackImport, null);
  const [armed, setArmed] = useState(false);

  if (!armed) {
    return (
      <div className="space-y-2">
        {state && <Notice kind="error">{state.error}</Notice>}
        <button onClick={() => setArmed(true)}
                className="text-sm text-stone-600 underline underline-offset-4 hover:text-rose-700">
          Undo this import
        </button>
      </div>
    );
  }

  return (
    <form action={action} className="max-w-lg space-y-3 rounded border border-rose-200 bg-rose-50 p-3">
      {state && <Notice kind="error">{state.error}</Notice>}
      <input type="hidden" name="id" value={id} />
      <p className="text-sm text-rose-900">
        This removes the {created} {noun} this import created, and nothing else —
        anything you have added or edited since stays. If something else was
        imported on top of these, that one has to be undone first.
      </p>
      <div className="flex items-center gap-4">
        <Submit label="Undo the import" busy="Undoing…" danger />
        <button type="button" onClick={() => setArmed(false)}
                className="text-sm text-stone-600 underline underline-offset-4">
          Keep it
        </button>
      </div>
    </form>
  );
}
