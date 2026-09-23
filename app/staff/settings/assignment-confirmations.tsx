"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveAssignmentConfirmations, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Decision 38 — assigned is not agreed. When on, an instructor is asked (in the
 * app, with one coalesced email per day) to confirm each class you assign them,
 * or hand it back. The assignment is never blocked or undone by their silence:
 * an unconfirmed class stays on the timetable.
 */
export default function AssignmentConfirmationsPanel({ enabled }: { enabled: boolean }) {
  const [state, action] = useFormState<PlainState, FormData>(saveAssignmentConfirmations, null);
  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="assignment_confirmations" defaultChecked={enabled} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Ask instructors to confirm classes you assign them</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              Instructors are asked to confirm classes you assign them. Unconfirmed
              classes stay on the timetable — nothing is blocked or undone by silence.
              One coalesced email per instructor per day; only reaches an instructor
              with a login. Off by default.
            </span>
          </span>
        </label>
        <div className="mt-3"><Save /></div>
      </div>
    </form>
  );
}
