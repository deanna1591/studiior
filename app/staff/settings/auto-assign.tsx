"use client";

import { useFormState } from "react-dom";
import { useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveAutoAssign, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Decision 43 — automatic instructor assignment is a per-tenant switch, off by
 * default. When off, materialising a recurring class never assigns anyone; the
 * owner assigns each class from the Schedule against the availability
 * instructors submitted, and whatever stays open is offered as an open shift.
 */
export default function AutoAssignPanel({ enabled }: { enabled: boolean }) {
  const [state, action] = useFormState<PlainState, FormData>(saveAutoAssign, null);
  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="auto_assign_open_classes" defaultChecked={enabled} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Assign instructors automatically</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              When on, new recurring classes are given an instructor automatically
              from their availability. When off, you assign each class from the
              Schedule. Off by default.
            </span>
          </span>
        </label>
        <div className="mt-3"><Save /></div>
      </div>
    </form>
  );
}
