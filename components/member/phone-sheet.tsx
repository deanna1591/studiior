"use client";

import { useFormState, useFormStatus } from "react-dom";
import { updateProfile } from "@/app/member/actions";
import { Note } from "@/components/member/ui";

/**
 * Decision 94 — the number is required, so when it is missing the app opens on a
 * sheet that cannot be dismissed until one is saved. There is no close control
 * and nothing behind it is reachable; it reuses the profile update action (scope
 * defaults to "phone", so only the phone column is written). The QR check-in and
 * class pages do not render this, so nobody is stuck at the door.
 */
function Save() {
  const { pending } = useFormStatus();
  return (
    <button
      disabled={pending}
      style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
      className="m-action mt-4 w-full rounded-xl text-[16px] font-semibold disabled:opacity-60"
    >
      {pending ? "Saving…" : "Save"}
    </button>
  );
}

export default function PhoneSheet() {
  const [state, action] = useFormState(updateProfile, null);

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Add your phone number"
      className="fixed inset-0 z-[60] flex items-end justify-center"
    >
      <div className="absolute inset-0" style={{ background: "rgb(20 16 14 / 0.42)" }} aria-hidden />
      <div className="relative z-10 w-full max-w-lg rounded-t-3xl bg-surface px-5 pb-[max(1.25rem,env(safe-area-inset-bottom))] pt-6 shadow-2xl">
        <h2 className="m-head text-[20px] text-ink">Add your phone number</h2>
        <p className="m-sub mt-1.5 text-ink-2">
          {"We'll call or text you about your classes and any changes to your bookings."}
        </p>

        <form action={action} className="mt-4">
          {state && !state.ok && (
            <Note ok={false}>
              {state.message}
              {state.phoneTaken && (
                <a href="/messages" className="mt-1 block font-semibold text-lime-text underline">
                  Message the studio
                </a>
              )}
            </Note>
          )}
          <input
            name="phone"
            type="tel"
            inputMode="tel"
            autoComplete="tel"
            autoFocus
            placeholder="0917 123 4567"
            className="m-tap w-full rounded-xl border border-line-2 bg-surface px-3.5 text-[16px] text-ink outline-none"
          />
          <Save />
        </form>
      </div>
    </div>
  );
}
