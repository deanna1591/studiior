"use client";

import { signUp } from "../actions";
import { Note, PrimaryButton, useAuthAction } from "@/components/member/ui";

export default function SignupForm() {
  const { error, pending, onSubmit } = useAuthAction(signUp, "/signup?sent=1");
  return (
    <form onSubmit={onSubmit} className="mt-6 space-y-4">
      {error && <Note ok={false}>{error}</Note>}
      <label className="block">
        <span className="m-sub mb-1.5 block font-medium text-ink">Your name</span>
        <input name="full_name" autoComplete="name"
               className="m-tap w-full rounded-lg border border-line-2 bg-surface px-3 text-[15px] text-ink" />
      </label>
      <label className="block">
        <span className="m-sub mb-1.5 block font-medium text-ink">Email</span>
        <input name="email" type="email" required autoComplete="email"
               className="m-tap w-full rounded-lg border border-line-2 bg-surface px-3 text-[15px] text-ink" />
        <span className="m-micro mt-1 block text-ink-3">
          Use the address the studio has for you and we&rsquo;ll find your history.
        </span>
      </label>
      <label className="block">
        <span className="m-sub mb-1.5 block font-medium text-ink">Choose a password</span>
        <input name="password" type="password" required minLength={8} autoComplete="new-password"
               className="m-tap w-full rounded-lg border border-line-2 bg-surface px-3 text-[15px] text-ink" />
      </label>
      <PrimaryButton pending={pending}>Create my account</PrimaryButton>
    </form>
  );
}
