"use client";

import { useFormState, useFormStatus } from "react-dom";
import { signIn } from "../actions";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";

function Submit() {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Signing in…" : "Sign in"}</button>;
}

export default function StaffLogin() {
  const [error, action] = useFormState(signIn, null);

  return (
    <div className="mx-auto max-w-sm px-5 py-16">
      <h1 className="text-xl font-semibold tracking-tight">Studiior — staff</h1>
      <p className="mb-6 mt-1 text-sm text-stone-500">Sign in to manage the schedule.</p>
      {error && <Notice kind="error">{error}</Notice>}
      <form action={action} className="space-y-4">
        <Field label="Email">
          <input name="email" type="email" required autoComplete="email" className={inputClass} />
        </Field>
        <Field label="Password">
          <input name="password" type="password" required autoComplete="current-password" className={inputClass} />
        </Field>
        <Submit />
      </form>
      <p className="mt-8 text-xs leading-relaxed text-stone-500">
        Seed logins: owner@example.com · manager@example.com ·
        frontdesk@example.com · instructor@example.com
        <br />
        Password: <code className="font-mono">reform-dev-password</code>
      </p>
    </div>
  );
}
