"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveClaiming, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

const field = "rounded border border-line-2 bg-surface px-3 py-2 text-[14px] text-ink outline-none";

/**
 * Claiming (149): invert how a month gets staffed. Off by default. When on, the
 * studio's open classes are CLAIMED by instructors (across the occurrence
 * horizon, further than members book) and staff approve every claim, instead of
 * staff assigning a roster for instructors to confirm. Core claims are capped
 * per week (soft — staff can approve past it); flex is unlimited.
 */
export default function ClaimingPanel({ enabled, defaultCap }: { enabled: boolean; defaultCap: number }) {
  const [state, action] = useFormState<PlainState, FormData>(saveClaiming, null);
  const [on, setOn] = useState(enabled);

  return (
    <form action={action} className="max-w-xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface p-4">
        <label className="flex items-start gap-3">
          <input type="checkbox" name="claiming_enabled" checked={on} onChange={(e) => setOn(e.target.checked)}
                 className="mt-0.5 h-4 w-4" />
          <span>
            <span className="block text-[13px] font-medium text-ink">Instructors claim their classes</span>
            <span className="mt-0.5 block text-[12px] leading-[17px] text-ink-3">
              Instead of assigning a roster for instructors to confirm, leave classes unassigned and
              let instructors claim the ones they want — you approve every claim. They see and claim
              across your whole timetable horizon, further ahead than members book. This does not
              change publication or your booking window.
            </span>
          </span>
        </label>
        {on && (
          <label className="mt-4 block border-t border-line pt-4">
            <span className="mb-1 block text-[13px] font-medium text-ink">Core claims per week</span>
            <span className="flex items-center gap-2">
              <input name="core_claim_default_cap" type="number" min={0} max={50} defaultValue={defaultCap}
                     className={`${field} w-20`} />
              <span className="text-[13px] text-ink-2">a week, by default</span>
            </span>
            <span className="mt-1 block text-[12px] leading-[17px] text-ink-3">
              A soft cap: an instructor cannot self-claim more core classes than this in a week, but
              you can still approve one past it. Flex classes are never capped. This is the studio
              default; an instructor with their own agreed cap keeps it.
            </span>
          </label>
        )}
        {/* Keep the cap posted when collapsed, so saving "off" does not write NaN. */}
        {!on && <input type="hidden" name="core_claim_default_cap" value={defaultCap} />}
        <div className="mt-4"><Save /></div>
      </div>
    </form>
  );
}
