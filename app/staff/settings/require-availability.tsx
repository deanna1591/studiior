"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveRequireAvailability, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Decision 46 — "no stated availability means not available", a per-tenant
 * switch, off by default. When on, the automatic assigners (and the Fill tool)
 * never place an instructor who has entered nothing; manual assignment from the
 * Schedule still works, with the existing warning (Decision 9). Under the switch
 * a standing pattern must carry an end date, so the studio checks month by month.
 */
export default function RequireAvailabilityPanel({ enabled }: { enabled: boolean }) {
  const [state, action] = useFormState<PlainState, FormData>(saveRequireAvailability, null);
  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="assign_requires_availability" defaultChecked={enabled} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Only assign instructors inside their stated availability</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              Off: an instructor with no availability on file can be assigned
              anywhere. On: the automatic assigner and the Fill tool skip an
              instructor who has not told you when they can teach, and a standing
              availability pattern needs an end date. You can still assign anyone
              by hand from the Schedule. Off by default.
            </span>
          </span>
        </label>
        <div className="mt-3"><Save /></div>
      </div>
    </form>
  );
}
