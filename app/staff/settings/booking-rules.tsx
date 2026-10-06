"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveBookingRules, type PlainState } from "./actions";
import { cutoffParts, cutoffLabel } from "@/lib/booking-rules";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Settings → Booking rules (manager-up). The three fields /welcome sets, now
 * reachable after onboarding, plus the late-cancel-consumes-credit switch. The
 * cancellation cut-off is entered as hours + minutes and stored as total
 * minutes (cancellation_cutoff_minutes); the live label reads 720 as "12 h".
 */
export default function BookingRulesPanel({
  windowDays, cutoffMinutes, requireWaiver, lateCancelConsumesCredit,
  checkinOpensBefore, checkinClosesAfter,
}: {
  windowDays: number;
  cutoffMinutes: number;
  requireWaiver: boolean;
  lateCancelConsumesCredit: boolean;
  checkinOpensBefore: number;
  checkinClosesAfter: number;
}) {
  const [state, action] = useFormState<PlainState, FormData>(saveBookingRules, null);
  const parts = cutoffParts(cutoffMinutes);
  const [hours, setHours] = useState(parts.hours);
  const [minutes, setMinutes] = useState(parts.minutes);
  const label = cutoffLabel(hours * 60 + minutes);

  const num =
    "w-20 rounded border border-line bg-surface px-2.5 py-1.5 text-[14px] text-ink num";

  return (
    <form action={action} className="max-w-2xl space-y-3">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      {/* Booking window */}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="block text-[13px] font-medium text-ink" htmlFor="booking_window_days">
          How far ahead members can book
        </label>
        <p className="mt-0.5 text-[12px] leading-[18px] text-ink-3">
          A membership plan&rsquo;s own window overrides this.
        </p>
        <div className="mt-2 flex items-center gap-2">
          <input id="booking_window_days" name="booking_window_days" type="number" min={0} step={1}
                 defaultValue={windowDays} className={num} />
          <span className="text-[13px] text-ink-2">days</span>
        </div>
      </div>

      {/* Cancellation cut-off — hours + minutes, stored as total minutes */}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <p className="text-[13px] font-medium text-ink">Cancellation cut-off</p>
        <p className="mt-0.5 text-[12px] leading-[18px] text-ink-3">
          How long before a class a member must cancel to avoid a late cancellation.
        </p>
        <div className="mt-2 flex items-center gap-2">
          <input name="cutoff_hours" type="number" min={0} step={1} value={hours}
                 onChange={(e) => setHours(Math.max(0, Math.floor(Number(e.target.value) || 0)))}
                 className={num} aria-label="Cut-off hours" />
          <span className="text-[13px] text-ink-2">h</span>
          <input name="cutoff_minutes" type="number" min={0} max={59} step={1} value={minutes}
                 onChange={(e) => setMinutes(Math.max(0, Math.floor(Number(e.target.value) || 0)))}
                 className={num} aria-label="Cut-off minutes" />
          <span className="text-[13px] text-ink-2">m</span>
          <span className="ml-1 text-[12px] text-ink-3">= {label}</span>
        </div>
      </div>

      {/* Check-in window — when the "Check in now" button opens and closes */}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <p className="text-[13px] font-medium text-ink">Check-in window</p>
        <p className="mt-0.5 text-[12px] leading-[18px] text-ink-3">
          When a member&rsquo;s class shows the &ldquo;Check in now&rdquo; button — from this
          many minutes before it starts until this many minutes after.
        </p>
        <div className="mt-2 flex flex-wrap items-center gap-2">
          <input name="checkin_opens_minutes_before" type="number" min={0} step={1}
                 defaultValue={checkinOpensBefore} className={num} aria-label="Opens minutes before" />
          <span className="text-[13px] text-ink-2">min before</span>
          <span className="mx-1 text-ink-3">·</span>
          <input name="checkin_closes_minutes_after" type="number" min={0} step={1}
                 defaultValue={checkinClosesAfter} className={num} aria-label="Closes minutes after" />
          <span className="text-[13px] text-ink-2">min after</span>
        </div>
      </div>

      {/* Waiver */}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="require_waiver" defaultChecked={requireWaiver} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Require a signed waiver</span> — a member must
            sign the studio&rsquo;s waiver before their first booking.
          </span>
        </label>
      </div>

      {/* Late cancel consumes credit + the no-show read-only line */}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="late_cancel_consumes_credit"
                 defaultChecked={lateCancelConsumesCredit} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">A late cancellation uses up the credit</span> —
            a member who cancels after the cut-off is charged the class, same as if
            they had come. Turn this off and a late cancellation returns the credit.
          </span>
        </label>
        <p className="mt-3 border-t border-line pt-3 text-[12px] leading-[18px] text-ink-3">
          A no-show uses up the credit. Someone booked in who never arrives is
          charged the class — there is nothing to turn off.
        </p>
      </div>

      <div><Save /></div>
    </form>
  );
}
