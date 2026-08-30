"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";
import { saveBookingBasics, saveStudioIdentity, type ActionState } from "../onboarding-actions";

function Submit({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Saving…" : label}</button>;
}

export default function WizardForms({
  step, studio, settings,
}: {
  step: number;
  studio: { name: string; slug: string; timezone: string; currency: string; country: string | null };
  settings: { booking_window_days: number; cancellation_cutoff_minutes: number; require_waiver: boolean };
}) {
  const [idState, idAction] = useFormState<ActionState, FormData>(saveStudioIdentity, null);
  const [bkState, bkAction] = useFormState<ActionState, FormData>(saveBookingBasics, null);

  if (step === 2) {
    return (
      <form action={idAction} className="space-y-4">
        {idState && <Notice kind="error">{idState.error}</Notice>}
        <Field label="Studio name">
          <input name="name" required defaultValue={studio.name} className={inputClass} />
        </Field>
        <Field label="Member app address">
          <div className="flex items-center gap-1">
            <input name="slug" required defaultValue={studio.slug} className={inputClass} />
            <span className="shrink-0 text-sm text-stone-500">.studiior.app</span>
          </div>
        </Field>
        <div className="grid grid-cols-2 gap-3">
          <Field label="Timezone">
            <input name="timezone" required defaultValue={studio.timezone} className={inputClass} />
          </Field>
          <Field label="Country">
            <input name="country" maxLength={2} defaultValue={studio.country ?? ""} className={inputClass} />
          </Field>
        </div>
        <Field label="Currency">
          <input name="currency" required maxLength={3} defaultValue={studio.currency} className={inputClass} />
          <p className="mt-1 text-xs text-stone-500">
            Every price is stored in this currency. Changing it later does not convert anything.
          </p>
        </Field>
        <Submit label="Continue" />
      </form>
    );
  }

  return (
    <form action={bkAction} className="space-y-4">
      {bkState && <Notice kind="error">{bkState.error}</Notice>}
      <Field label="How far ahead can members book? (days)">
        <input name="booking_window_days" type="number" min={1} required
               defaultValue={settings.booking_window_days} className={inputClass} />
      </Field>
      <Field label="Cancellation cutoff (minutes before class)">
        <input name="cancellation_cutoff_minutes" type="number" min={0} required
               defaultValue={settings.cancellation_cutoff_minutes} className={inputClass} />
        <p className="mt-1 text-xs text-stone-500">
          720 is twelve hours. Cancelling after this is a late cancellation and
          consumes the credit.
        </p>
      </Field>
      <Field label="Waiver">
        <label className="flex items-center gap-2 pt-1 text-sm">
          <input type="checkbox" name="require_waiver" defaultChecked={settings.require_waiver} />
          Members must sign a waiver before their first booking
        </label>
      </Field>
      <Submit label="Finish and go to the dashboard" />
    </form>
  );
}
