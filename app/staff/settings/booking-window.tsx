"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass, inputClass } from "@/components/ui";
import { saveBookingWindow, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Decision 36 — how far ahead members can book. This is the studio default;
 * a membership plan's own window overrides it (book_class rule 2.1.2, resolved
 * by member_booking_window_days, which the member app's "Opens for booking"
 * screen reads too). Distinct from the timetable horizon above, which is how far
 * ahead classes are generated — this is how far ahead a member may reserve one.
 */
export default function BookingWindowPanel({ value }: { value: number }) {
  const [state, action] = useFormState<PlainState, FormData>(saveBookingWindow, null);
  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="block text-[13px] leading-[20px] text-ink">
          <span className="font-medium">How far ahead members can book</span>
          <span className="block text-[12px] leading-[18px] text-ink-3">
            A membership plan&rsquo;s own window overrides this. Between 1 and 730 days.
          </span>
          <span className="mt-2 flex items-end gap-2">
            <input name="booking_window_days" type="number" min={1} max={730} required
                   defaultValue={value} className={`${inputClass} w-28`} />
            <span className="pb-2 text-[13px] text-ink-2">days</span>
          </span>
        </label>
        <div className="mt-3"><Save /></div>
      </div>
    </form>
  );
}
