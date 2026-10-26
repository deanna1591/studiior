"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass, inputClass } from "@/components/ui";
import { saveOpeningDate, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Decision 14(d) — the owner states the opening date. Blank means it is inferred
 * from the first attended class (c); set, it overrides the inference so a studio
 * testing its own check-in and pay flows before launch does not open itself.
 */
export default function OpeningDatePanel({ openedOn }: { openedOn: string | null }) {
  const [state, action] = useFormState<PlainState, FormData>(saveOpeningDate, null);
  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <p className="text-[13px] font-medium leading-[18px] text-ink">Opening date</p>
        <p className="mt-0.5 text-[12px] leading-[18px] text-ink-3">
          Leave blank if you have already opened. Until this date no convert, keep
          or retention emails or tasks are sent and member health reads
          insufficient history.
        </p>
        <div className="mt-2.5 flex flex-wrap items-end gap-x-3 gap-y-2">
          <label className="text-[12px] leading-[16px] text-ink-2">
            <span className="mb-1 block">Opens on</span>
            <input name="opened_on" type="date" defaultValue={openedOn ?? ""}
                   className={`${inputClass} w-44`} />
          </label>
          <span className="pb-1"><Save /></span>
        </div>
      </div>
    </form>
  );
}
