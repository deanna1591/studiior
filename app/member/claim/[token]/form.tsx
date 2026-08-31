"use client";

import { useFormState } from "react-dom";
import { claimAccount, type ClaimState } from "../../actions";
import { Note, PrimaryButton } from "@/components/member/ui";

export default function ClaimForm({
  token, email, slug,
}: { token: string; email: string; slug: string }) {
  const [state, action] = useFormState<ClaimState, FormData>(claimAccount, null);
  return (
    <form action={action} className="mt-6 space-y-4">
      {state && <Note ok={false}>{state.error}</Note>}
      <input type="hidden" name="token" value={token} />
      <p className="m-sub text-ink-2">
        Signing in as <span className="text-ink">{email}</span>
      </p>
      <label className="block">
        <span className="m-sub mb-1.5 block font-medium text-ink">Your name</span>
        <input name="full_name" autoComplete="name"
               className="m-tap w-full rounded-lg border border-line-2 bg-surface px-3 text-[15px] text-ink" />
      </label>
      <label className="block">
        <span className="m-sub mb-1.5 block font-medium text-ink">Choose a password</span>
        <input name="password" type="password" required minLength={8} autoComplete="new-password"
               className="m-tap w-full rounded-lg border border-line-2 bg-surface px-3 text-[15px] text-ink" />
        <span className="m-micro mt-1 block text-ink-3">At least 8 characters.</span>
      </label>
      <PrimaryButton>Set up my account</PrimaryButton>
      <input type="hidden" name="slug" value={slug} />
    </form>
  );
}
