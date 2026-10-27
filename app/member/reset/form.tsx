"use client";

import { completePasswordReset } from "../actions";
import { PrimaryButton, useAuthAction } from "@/components/member/ui";
import { MIN_PASSWORD, resetRedirect } from "@/lib/password-reset";

/**
 * Decision 84. On success the client navigates to the role's login — a member
 * server-action redirect would render the staff app (see useAuthAction) — where
 * ?reset=1 acknowledges it. The recovery session set the new password; other
 * sessions are signed out server-side (scope 'others').
 */
export default function ResetForm({ role }: { role: "member" | "instructor" }) {
  const { error, pending, onSubmit } = useAuthAction(completePasswordReset, resetRedirect(role));

  return (
    <form onSubmit={onSubmit} className="m-card mt-5 px-4 py-4">
      <label className="m-sub block text-ink-2" htmlFor="password">New password</label>
      <input id="password" name="password" type="password" required autoComplete="new-password"
             minLength={MIN_PASSWORD}
             className="m-tap mt-1 w-full rounded-xl border border-[color:var(--line-2)] bg-[color:var(--surface)] px-3 text-[15px] text-ink" />
      <label className="m-sub mt-4 block text-ink-2" htmlFor="confirm">Confirm new password</label>
      <input id="confirm" name="confirm" type="password" required autoComplete="new-password"
             minLength={MIN_PASSWORD}
             className="m-tap mt-1 w-full rounded-xl border border-[color:var(--line-2)] bg-[color:var(--surface)] px-3 text-[15px] text-ink" />
      <p className="m-micro mt-2 text-ink-3">At least {MIN_PASSWORD} characters.</p>
      {error && (
        <p className="mt-3 text-[13px] leading-[19px] text-ink" role="alert"
           style={{ borderLeft: "3px solid var(--coral)", paddingLeft: 8 }}>
          {error}
        </p>
      )}
      <div className="mt-4"><PrimaryButton pending={pending}>Set a new password</PrimaryButton></div>
    </form>
  );
}
