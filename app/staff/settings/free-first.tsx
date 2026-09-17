"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveFreeFirst, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Decision 30's switch — the door. Off by default: a studio that never turns it
 * on shows no "first class free" anywhere, in the member app or here. On, anyone
 * who signs up on their own books their first class for nothing — no host, no
 * invite, no card. It shares the guest pass's once-ever rule: one free class per
 * person in total, whichever door they came through. Turning it back off never
 * charges anyone already booked — their seat is an ordinary comp booking.
 */
export default function FreeFirstPanel({
  enabled, peakAllowed,
}: { enabled: boolean; peakAllowed: boolean }) {
  const [state, action] = useFormState<PlainState, FormData>(saveFreeFirst, null);

  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="free_first_class_enabled" defaultChecked={enabled} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">A new member&rsquo;s first class is free</span> — anyone
            signs up on their own and their first class costs nothing. No card needed.
            <span className="block text-[12px] leading-[18px] text-ink-3">
              One free class per person, ever — shared with guest passes, so someone brought as a
              guest cannot also get a free signup class. They sign the waiver in the app before the
              class, and become an ordinary member afterwards.
            </span>
          </span>
        </label>

        <label className="mt-3 flex items-start gap-2.5 border-t border-line pt-3">
          <input type="checkbox" name="free_first_peak_allowed" defaultChecked={peakAllowed} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Allow free first classes at peak times</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              A free seat is one a paying member cannot have, and the instructor is paid regardless.
              Turn this off to keep free classes out of your busiest hours; they can still book those
              paying. (Only matters if you use peak hours.)
            </span>
          </span>
        </label>

        <div className="mt-3"><Save /></div>
      </div>
    </form>
  );
}
