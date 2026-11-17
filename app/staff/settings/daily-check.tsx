"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveDailyCheck, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/** Decision 108 — the daily read-only money/data check, emailed to the owner at
 *  7:00 studio time. On by default. */
export default function DailyCheckPanel({ enabled }: { enabled: boolean }) {
  const [state, action] = useFormState<PlainState, FormData>(saveDailyCheck, null);
  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="daily_check_enabled" defaultChecked={enabled} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Email me the daily check</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              Every morning at 7:00 the owner gets one short email listing anything that looks off:
              a payment attached to nothing, a member double-booked, an unsent email, a bounce, and
              the like. Nothing is changed by the check. On by default.
            </span>
          </span>
        </label>
        <div className="mt-3"><Save /></div>
      </div>
    </form>
  );
}
