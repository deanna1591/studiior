"use client";

import { useFormState, useFormStatus } from "react-dom";
import { completePasswordReset } from "../actions";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";
import { MIN_PASSWORD } from "@/lib/password-reset";

function Submit() {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Saving…" : "Set a new password"}</button>;
}

/** Decision 84. On success the action signs out other sessions and redirects
 *  to /login?reset=1 (a staff server-action redirect is fine on this host). */
export default function ResetForm() {
  const [error, action] = useFormState(completePasswordReset, null);
  return (
    <>
      {error && <Notice kind="error">{error}</Notice>}
      <form action={action} className="space-y-4">
        <Field label="New password" hint={`At least ${MIN_PASSWORD} characters.`}>
          <input name="password" type="password" required autoComplete="new-password"
                 minLength={MIN_PASSWORD} className={inputClass} />
        </Field>
        <Field label="Confirm new password">
          <input name="confirm" type="password" required autoComplete="new-password"
                 minLength={MIN_PASSWORD} className={inputClass} />
        </Field>
        <Submit />
      </form>
    </>
  );
}
