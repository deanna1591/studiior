"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";
import { joinTeam, type JoinState } from "./actions";

function Submit() {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Creating your account…" : "Create account and sign in"}</button>;
}

export default function JoinForm({ token, email }: { token: string; email: string }) {
  const [state, action] = useFormState<JoinState, FormData>(joinTeam, null);
  return (
    <form action={action} className="space-y-4">
      {state && <Notice kind="error">{state.error}</Notice>}
      <input type="hidden" name="token" value={token} />
      <input type="hidden" name="email" value={email} />
      <Field label="Email">
        <input value={email} readOnly disabled className={`${inputClass} bg-line text-ink-3`} />
        <p className="mt-1 text-xs text-ink-3">The invite was sent here, so this is the address your account uses.</p>
      </Field>
      <Field label="Your name">
        <input name="full_name" required autoComplete="name" className={inputClass} />
      </Field>
      <Field label="Password">
        <input name="password" type="password" required minLength={8} autoComplete="new-password" className={inputClass} />
        <p className="mt-1 text-xs text-ink-3">At least 8 characters.</p>
      </Field>
      <Submit />
    </form>
  );
}
