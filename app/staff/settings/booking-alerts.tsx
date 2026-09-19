"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveBookingAlerts, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Decision 33 amendment — a per-tenant switch (off by default), no instructor
 * opt-out. When on, the assigned instructor is emailed when a booking lands on
 * or leaves their class — coalesced to one notice per class per 15 minutes, so
 * a busy studio is not 100 emails a week but at most one per class per quarter
 * hour, with the running headcount and what changed.
 */
export default function BookingAlertsPanel({ enabled }: { enabled: boolean }) {
  const [state, action] = useFormState<PlainState, FormData>(saveBookingAlerts, null);
  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="instructor_booking_alerts" defaultChecked={enabled} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Email instructors about bookings on their classes</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              The assigned instructor is told when a booking lands on or leaves their
              class. Coalesced to one email per class per 15 minutes — the running
              headcount, spaces left, and what changed. Instructors cannot turn this
              off; only reaches an instructor with a login. Off by default.
            </span>
          </span>
        </label>
        <div className="mt-3"><Save /></div>
      </div>
    </form>
  );
}
