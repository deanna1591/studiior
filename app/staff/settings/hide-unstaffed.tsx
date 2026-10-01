"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveHideUnstaffed, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Decision 48 — hide unstaffed classes from members, per tenant. When on, a
 * class nobody is teaching yet stays off the member app and the website embed
 * (and closed to new bookings) until someone is assigned. Members already
 * booked keep seeing their class. Off by default.
 */
export default function HideUnstaffedPanel({ enabled }: { enabled: boolean }) {
  const [state, action] = useFormState<PlainState, FormData>(saveHideUnstaffed, null);
  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="hide_unstaffed_from_members" defaultChecked={enabled} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Only show classes that have an instructor</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              A class nobody is teaching yet stays off the member app and the
              website until you assign someone. Members already booked keep
              seeing their class. Off by default.
            </span>
          </span>
        </label>
        <div className="mt-3"><Save /></div>
      </div>
    </form>
  );
}
