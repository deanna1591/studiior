"use client";

import { useFormState } from "react-dom";
import { PrimaryButton } from "@/components/member/ui";
import { instructorSignIn, type SignInState } from "./actions";

export default function LoginForm() {
  const [state, action] = useFormState<SignInState, FormData>(instructorSignIn, null);
  return (
    <form action={action} className="m-card mt-5 px-4 py-4">
      <label className="m-sub block text-ink-2" htmlFor="email">Email</label>
      <input id="email" name="email" type="email" required autoComplete="email"
             className="m-tap mt-1 w-full rounded-xl border border-[color:var(--line-2)] bg-[color:var(--surface)] px-3 text-[15px] text-ink" />
      <label className="m-sub mt-4 block text-ink-2" htmlFor="password">Password</label>
      <input id="password" name="password" type="password" required autoComplete="current-password"
             className="m-tap mt-1 w-full rounded-xl border border-[color:var(--line-2)] bg-[color:var(--surface)] px-3 text-[15px] text-ink" />
      {state && "error" in state && (
        <p className="mt-3 text-[13px] leading-[19px] text-ink" role="alert"
           style={{ borderLeft: "3px solid var(--coral)", paddingLeft: 8 }}>
          {state.error}
        </p>
      )}
      <div className="mt-4"><PrimaryButton>Sign in</PrimaryButton></div>
    </form>
  );
}
