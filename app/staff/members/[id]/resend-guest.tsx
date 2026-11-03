"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonClass } from "@/components/ui";
import { resendGuestInvite, type InviteState } from "../actions";

function Go({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return (
    <button className={buttonClass} disabled={pending}>
      {pending ? "Sending…" : label}
    </button>
  );
}

/**
 * Decision 26(b): re-send a guest's claim+waiver invite (the guest_invite email,
 * not the plain member_invite). A fresh link, the old one revoked.
 */
export function ResendGuestInvite({
  memberId, label,
}: { memberId: string; label: string }) {
  const [state, action] = useFormState<InviteState, FormData>(resendGuestInvite, null);
  return (
    <div>
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <form action={action}>
        <input type="hidden" name="member_id" value={memberId} />
        <Go label={label} />
      </form>
    </div>
  );
}
