"use client";

import { PrimaryButton, useAuthAction } from "@/components/member/ui";
import { claimInstructor } from "./actions";

export default function ClaimForm({
  token, email, name,
}: { token: string; email: string; name: string }) {
  const { error, pending, onSubmit } = useAuthAction(claimInstructor, "/instructor");
  return (
    <form onSubmit={onSubmit} className="m-card mt-4 px-4 py-4">
      <input type="hidden" name="token" value={token} />
      <label className="m-sub block text-ink-2">Your email</label>
      <p className="mt-0.5 text-[15px] leading-5 text-ink">{email}</p>

      <label className="m-sub mt-4 block text-ink-2" htmlFor="full_name">Your name</label>
      <input id="full_name" name="full_name" defaultValue={name}
             className="m-tap mt-1 w-full rounded-xl border border-[color:var(--line-2)] bg-[color:var(--surface)] px-3 text-[15px] text-ink" />

      <label className="m-sub mt-4 block text-ink-2" htmlFor="password">Choose a password</label>
      <input id="password" name="password" type="password" required minLength={8}
             autoComplete="new-password"
             className="m-tap mt-1 w-full rounded-xl border border-[color:var(--line-2)] bg-[color:var(--surface)] px-3 text-[15px] text-ink" />
      <p className="m-sub mt-1 text-ink-3">Eight characters or more.</p>

      {error && (
        <p className="mt-3 text-[13px] leading-[19px] text-ink" role="alert"
           style={{ borderLeft: "3px solid var(--coral)", paddingLeft: 8 }}>
          {error}
        </p>
      )}

      <div className="mt-4"><PrimaryButton pending={pending}>Set it and go in</PrimaryButton></div>
    </form>
  );
}
