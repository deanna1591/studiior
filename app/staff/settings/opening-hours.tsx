"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass, inputClass } from "@/components/ui";
import { saveOpeningHours, type PlainState } from "./actions";

function Buttons() {
  const { pending } = useFormStatus();
  return (
    <div className="mt-3 flex gap-2">
      <button name="intent" value="save" className={buttonQuietClass} disabled={pending}>
        {pending ? "Saving…" : "Save"}
      </button>
      <button name="intent" value="clear" disabled={pending}
              className="rounded border border-line px-3 py-1.5 text-[13px] text-ink-2 disabled:opacity-60">
        Clear
      </button>
    </div>
  );
}

/**
 * Decision 44 — the studio's one opening window. Optional: unset by default, and
 * Clear sets it back to nothing. When set, a class that STARTS outside these
 * hours is flagged when you create it (and on a drag) — never blocked, and the
 * end may run past close (a 22:00–22:50 class closes the studio at a 22:00 close).
 * Per-weekday hours and closures-by-date are deferred.
 */
export default function OpeningHoursPanel({ open, close }: { open: string | null; close: string | null }) {
  const [state, action] = useFormState<PlainState, FormData>(saveOpeningHours, null);
  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <p className="text-[13px] font-medium leading-[18px] text-ink">Opening hours</p>
        <p className="mt-0.5 text-[12px] leading-[18px] text-ink-3">
          Optional. Classes that start outside these hours are flagged when you
          create them — never blocked.
        </p>
        <div className="mt-2.5 flex flex-wrap items-end gap-x-3 gap-y-2">
          <label className="text-[12px] leading-[16px] text-ink-2">
            <span className="mb-1 block">Opens</span>
            <input name="open_time" type="time" step={900} defaultValue={open ?? ""}
                   className={`${inputClass} w-32`} />
          </label>
          <span className="pb-2 text-[13px] text-ink-3">to</span>
          <label className="text-[12px] leading-[16px] text-ink-2">
            <span className="mb-1 block">Closes</span>
            <input name="close_time" type="time" step={900} defaultValue={close ?? ""}
                   className={`${inputClass} w-32`} />
          </label>
        </div>
        <Buttons />
      </div>
    </form>
  );
}
