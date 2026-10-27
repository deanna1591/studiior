"use client";

import { Suspense } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { useFormState, useFormStatus } from "react-dom";
import { signIn } from "../actions";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";

function Submit() {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Signing in…" : "Sign in"}</button>;
}

/** Decision 84: a finished reset returns here with ?reset=1. useSearchParams
 *  needs a Suspense boundary, so it lives in its own component. */
function ResetNotice() {
  return useSearchParams().get("reset")
    ? <Notice kind="ok">Password updated. Sign in with your new password.</Notice>
    : null;
}

export default function StaffLogin() {
  const [error, action] = useFormState(signIn, null);

  return (
    <div className="mx-auto max-w-sm px-5 py-16">
      <h1 className="text-xl font-semibold tracking-tight">Studiior — staff</h1>
      <p className="mb-6 mt-1 text-sm text-ink-3">Sign in to manage the schedule.</p>
      <Suspense fallback={null}><ResetNotice /></Suspense>
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
      {/* Decision 84 */}
      <Link href="/forgot" className="mt-4 block text-sm text-ink-3 underline underline-offset-4">
        Forgot your password?
      </Link>
      {/*
        Local development only. The condition is written inline, around the JSX
        itself, rather than wrapped in a <DevOnly> component: Next replaces
        process.env.NODE_ENV at build time, so `false && (...)` is eliminated
        and these strings are absent from the production bundle entirely. A
        component taking children would still construct and ship the markup and
        only decline to render it, which puts the credentials back in the
        JavaScript anybody can read.
      */}
      {process.env.NODE_ENV === "development" && (
        <p className="mt-8 text-xs leading-relaxed text-ink-3">
          Seed logins: owner@example.com · manager@example.com ·
          frontdesk@example.com · instructor@example.com
          <br />
          Password: <code className="font-mono">reform-dev-password</code>
        </p>
      )}
    </div>
  );
}
