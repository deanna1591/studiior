"use client";

import { useFormState, useFormStatus } from "react-dom";
import { bringGuest } from "@/app/member/actions";
import type { BookResult } from "@/app/member/actions";

function Submit() {
  const { pending } = useFormStatus();
  return (
    <button type="submit" disabled={pending}
            className="m-tap m-press w-full rounded-full py-3 text-[14px] font-bold"
            style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
      {pending ? "Booking your guest…" : "Book my guest"}
    </button>
  );
}

/**
 * Decision 26 — bring a guest, their first class is free. A native <details> so
 * it opens on demand and adds no weight until a member wants it. The rules are
 * said plainly (one free class ever; one guest at a time); the refusals come
 * back from book_guest as whole sentences.
 */
export default function GuestInvite({ occurrenceId }: { occurrenceId: string }) {
  const [state, action] = useFormState<BookResult, FormData>(bringGuest, null);

  return (
    <details className="m-card mt-3 overflow-hidden">
      <summary className="m-press flex cursor-pointer list-none items-center justify-between p-4">
        <span>
          <span className="m-name block text-ink">Bring a guest</span>
          <span className="m-subtle text-ink-3">Their first class is free.</span>
        </span>
        <span className="m-micro rounded-full px-2 py-0.5"
              style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>Free</span>
      </summary>

      <form action={action} className="border-t border-line p-4">
        {state && (
          <p className={`m-sub mb-3 rounded-xl px-3 py-2 ${state.ok ? "text-ink" : "text-ink"}`}
             role="status"
             style={{ background: state.ok ? "var(--accent-chip)" : "var(--coral-tint)" }}>
            {state.message}
          </p>
        )}
        {!state?.ok && (
          <>
            <input type="hidden" name="occurrence_id" value={occurrenceId} />
            <div className="flex gap-2">
              <input name="guest_first" placeholder="First name" autoComplete="off"
                     className="m-tap w-1/2 rounded-xl border border-line bg-surface px-3 py-2.5 text-[15px] text-ink" />
              <input name="guest_last" placeholder="Last name" autoComplete="off"
                     className="m-tap w-1/2 rounded-xl border border-line bg-surface px-3 py-2.5 text-[15px] text-ink" />
            </div>
            <input name="guest_email" type="email" inputMode="email" placeholder="Guest's email" autoComplete="off"
                   className="m-tap mt-2 w-full rounded-xl border border-line bg-surface px-3 py-2.5 text-[15px] text-ink" />
            <p className="m-micro mt-2 text-ink-3">
              One free class per person, ever. You can bring another guest once this one has come.
              They&rsquo;ll get an email to set up and sign the waiver before the class.
            </p>
            <div className="mt-3"><Submit /></div>
          </>
        )}
      </form>
    </details>
  );
}
