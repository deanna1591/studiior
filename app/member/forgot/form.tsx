"use client";

import { useFormState } from "react-dom";
import { requestPasswordReset } from "../actions";
import { PrimaryButton } from "@/components/member/ui";
import { RESET_SENT } from "@/lib/password-reset";

/**
 * Decision 84. The request form does NOT navigate on success (unlike the login
 * forms) — it stays and shows the one fixed line, which never reveals whether
 * the address has an account. A plain <form action> is right here: there is
 * nothing to redirect to and no "used" state to race (see useAuthAction).
 */
export default function ForgotForm({ instructor }: { instructor: boolean }) {
  const [state, action] = useFormState(requestPasswordReset, null);
  const sent = !!state && "ok" in state;

  return (
    <form action={action} className="m-card mt-5 px-4 py-4">
      {sent ? (
        <p className="m-sub text-ink" role="status"
           style={{ borderLeft: "3px solid var(--lime-text)", paddingLeft: 8 }}>
          {RESET_SENT}
        </p>
      ) : (
        <>
          <input type="hidden" name="role" value={instructor ? "instructor" : "member"} />
          <label className="m-sub block text-ink-2" htmlFor="email">Email</label>
          <input id="email" name="email" type="email" required autoComplete="email"
                 inputMode="email"
                 className="m-tap mt-1 w-full rounded-xl border border-[color:var(--line-2)] bg-[color:var(--surface)] px-3 text-[15px] text-ink" />
          {state && "error" in state && (
            <p className="mt-3 text-[13px] leading-[19px] text-ink" role="alert"
               style={{ borderLeft: "3px solid var(--coral)", paddingLeft: 8 }}>
              {state.error}
            </p>
          )}
          <div className="mt-4"><PrimaryButton>Send the reset link</PrimaryButton></div>
        </>
      )}
    </form>
  );
}
