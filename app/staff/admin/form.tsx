"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";
import { provisionStudio, type ActionState } from "../onboarding-actions";

function Submit() {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Creating…" : "Create studio and invite"}</button>;
}

export default function ProvisionForm() {
  const [state, action] = useFormState<ActionState, FormData>(provisionStudio, null);

  return (
    <form action={action} className="max-w-md space-y-4">
      {state && <Notice kind="error">{state.error}</Notice>}
      <Field label="Studio name">
        <input name="name" required className={inputClass} placeholder="Bright Pilates" />
      </Field>
      <Field label="Slug">
        <input name="slug" required className={inputClass} placeholder="bright-pilates" />
        <p className="mt-1 text-xs text-stone-500">
          Their member app will live at <code>{"{slug}"}.studiior.app</code>. The owner can change it in the wizard.
        </p>
      </Field>
      <div className="grid grid-cols-2 gap-3">
        <Field label="Timezone">
          <input name="timezone" required defaultValue="Europe/Prague" className={inputClass} />
        </Field>
        <Field label="Country">
          <input name="country" required defaultValue="CZ" maxLength={2} className={inputClass} />
        </Field>
      </div>
      <Field label="Currency">
        <input name="currency" required defaultValue="CZK" maxLength={3} className={inputClass} />
      </Field>
      <Field label="Owner email">
        <input name="owner_email" type="email" required className={inputClass}
               placeholder="owner@brightpilates.com" />
        <p className="mt-1 text-xs text-stone-500">
          The invite link is generated here; sending it is still a manual step.
        </p>
      </Field>
      <Submit />
    </form>
  );
}
