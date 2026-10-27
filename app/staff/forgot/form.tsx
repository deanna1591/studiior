"use client";

import Link from "next/link";
import { useFormState, useFormStatus } from "react-dom";
import { requestPasswordReset } from "../actions";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";
import { RESET_SENT } from "@/lib/password-reset";

function Submit() {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Sending…" : "Send the reset link"}</button>;
}

/**
 * Decision 84. Stays on success and shows the one fixed line (which never
 * reveals whether the address has an account), rather than navigating.
 */
export default function ForgotForm() {
  const [state, action] = useFormState(requestPasswordReset, null);
  const sent = !!state && "ok" in state;

  if (sent) {
    return (
      <>
        <Notice kind="ok">{RESET_SENT}</Notice>
        <Link href="/login" className="mt-4 block text-sm text-ink-3 underline underline-offset-4">
          Back to sign in
        </Link>
      </>
    );
  }
  return (
    <>
      {state && "error" in state && <Notice kind="error">{state.error}</Notice>}
      <form action={action} className="space-y-4">
        <Field label="Email">
          <input name="email" type="email" required autoComplete="email" className={inputClass} />
        </Field>
        <Submit />
      </form>
      <Link href="/login" className="mt-4 block text-sm text-ink-3 underline underline-offset-4">
        Back to sign in
      </Link>
    </>
  );
}
