"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveCover, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

const field = "rounded border border-line-2 bg-surface px-3 py-2 text-[14px] text-ink outline-none";

/**
 * Auto-accept cover (156). A cover request three weeks out can wait for a
 * decision; one for tomorrow morning cannot — nobody has time for an approval
 * round, and a class going unstaffed because staff were asleep is worse than one
 * covered by whoever was fastest. Off by default; when on, a request inside the
 * escalation window is taken by the first qualified instructor, staff told.
 */
export default function CoverPanel({ enabled, hours }: { enabled: boolean; hours: number }) {
  const [state, action] = useFormState<PlainState, FormData>(saveCover, null);
  const [on, setOn] = useState(enabled);

  return (
    <form action={action} className="max-w-xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface p-4">
        <label className="flex items-start gap-3">
          <input type="checkbox" name="cover_auto_accept_enabled" checked={on} onChange={(e) => setOn(e.target.checked)}
                 className="mt-0.5 h-4 w-4" />
          <span>
            <span className="block text-[13px] font-medium text-ink">Let urgent cover be taken without approval</span>
            <span className="mt-0.5 block text-[12px] leading-[17px] text-ink-3">
              When a cover request is close to the class, the first qualified, available instructor to take
              it gets it — no approval round — and you are told who took it. Every check still applies
              (qualified, free, not already teaching); only the approval step is skipped, and the core cap
              does not apply to an urgent cover. Requests further out still wait for you.
            </span>
          </span>
        </label>
        <label className="mt-4 block border-t border-line pt-4">
          <span className="mb-1 block text-[13px] font-medium text-ink">How close counts as urgent</span>
          <span className="flex items-center gap-2">
            <input name="cover_escalation_hours" type="number" min={1} max={72} defaultValue={hours}
                   className={`${field} w-20`} />
            <span className="text-[13px] text-ink-2">hours before the class</span>
          </span>
          <span className="mt-1 block text-[12px] leading-[17px] text-ink-3">
            The same window that escalates an unanswered cover request. Inside it, auto-accept applies;
            outside it, cover waits for your approval.
          </span>
        </label>
        <div className="mt-4"><Save /></div>
      </div>
    </form>
  );
}
