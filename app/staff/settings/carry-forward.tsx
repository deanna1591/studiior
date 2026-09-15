"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveCarryForward, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

const field = "rounded border border-line-2 bg-surface px-3 py-2 text-[14px] text-ink outline-none";

/**
 * G — carry a silent instructor's roster forward. Off by default. When an
 * instructor is sent a month's roster and says nothing for the deadline, last
 * month's confirmed classes (same weekday, time and class type) are assigned
 * into this month's open slots rather than left unstaffed.
 */
export default function CarryForwardPanel({ enabled, days }: { enabled: boolean; days: number }) {
  const [state, action] = useFormState<PlainState, FormData>(saveCarryForward, null);
  const [on, setOn] = useState(enabled);

  return (
    <form action={action} className="max-w-xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface p-4">
        <label className="flex items-start gap-3">
          <input type="checkbox" name="carry_forward_enabled" checked={on} onChange={(e) => setOn(e.target.checked)}
                 className="mt-0.5 h-4 w-4" />
          <span>
            <span className="block text-[13px] font-medium text-ink">Carry a silent roster forward</span>
            <span className="mt-0.5 block text-[12px] leading-[17px] text-ink-3">
              If an instructor is sent their roster and says nothing by the deadline, last month’s
              confirmed classes are assigned into this month’s open slots — matched on weekday, time
              and class type. Only what they confirmed carries; anything moved, archived, or with no
              match is left for you, and you see why.
            </span>
          </span>
        </label>
        {on && (
          <label className="mt-4 block border-t border-line pt-4">
            <span className="mb-1 block text-[13px] font-medium text-ink">Deadline</span>
            <span className="flex items-center gap-2">
              <input name="roster_confirm_days" type="number" min={1} max={31} defaultValue={days}
                     className={`${field} w-20`} />
              <span className="text-[13px] text-ink-2">days after they are notified</span>
            </span>
          </label>
        )}
        {/* Keep the days value posted even when collapsed, so saving "off" does
            not write NaN over the deadline. */}
        {!on && <input type="hidden" name="roster_confirm_days" value={days} />}
        <div className="mt-4"><Save /></div>
      </div>
    </form>
  );
}
