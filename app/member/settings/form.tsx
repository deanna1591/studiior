"use client";

import { useFormState, useFormStatus } from "react-dom";
import { updateEmailPreferences } from "../actions";

type Prefs = {
  booking_email: boolean;
  reminder_email: boolean;
  waitlist_email: boolean;
  credit_expiry_email: boolean;
  milestone_email: boolean;
};

/**
 * One row per switch, the whole row tappable.
 *
 * A 20px checkbox is under the 44px floor the rest of this app holds to, so the
 * label carries the target and the box is decoration inside it.
 */
const ROWS: { name: keyof Prefs; label: string; hint: string }[] = [
  { name: "booking_email",       label: "Booking confirmations",
    hint: "When you book a class." },
  { name: "reminder_email",      label: "Class reminders",
    hint: "The day before, so you do not forget." },
  { name: "waitlist_email",      label: "Waitlist offers",
    hint: "When a place opens up. Turning this off means you will not know." },
  { name: "credit_expiry_email", label: "Credits running out",
    hint: "A week before classes on a pack expire." },
  { name: "milestone_email",     label: "Milestones",
    hint: "Your hundredth class, and the like." },
];

function Save() {
  const { pending } = useFormStatus();
  return (
    <button className="m-action mt-6 w-full rounded-lg bg-ink text-[15px] font-medium text-surface"
            disabled={pending}>
      {pending ? "Saving…" : "Save"}
    </button>
  );
}

export default function PreferencesForm({ initial }: { initial: Prefs }) {
  const [state, action] = useFormState(updateEmailPreferences, null);

  return (
    <form action={action}>
      <ul className="divide-y divide-line border-y border-line">
        {ROWS.map((r) => (
          <li key={r.name}>
            <label className="flex min-h-[56px] cursor-pointer items-center justify-between gap-4 py-3">
              <span>
                <span className="m-body block text-ink">{r.label}</span>
                <span className="m-micro block text-ink-3">{r.hint}</span>
              </span>
              <input
                type="checkbox"
                name={r.name}
                defaultChecked={initial[r.name]}
                // --lime-text, not --lime: themeVars() remaps the studio's accent onto
                // the lime token names, and the raw fill is a pale colour the
                // browser draws a white tick on. There is no --accent variable at
                // all, so the first version of this silently rendered system blue.
                className="h-5 w-5 shrink-0 accent-[var(--lime-text)]"
              />
            </label>
          </li>
        ))}
      </ul>

      <Save />

      {state === "ok" && (
        <p className="m-sub mt-3 text-ink-2" role="status">Saved.</p>
      )}
      {state && state !== "ok" && (
        <p className="m-sub mt-3 text-ink" role="alert"
           style={{ background: "var(--coral-tint)", borderLeft: "3px solid var(--coral)",
                    padding: "8px 10px" }}>
          {state}
        </p>
      )}
    </form>
  );
}
