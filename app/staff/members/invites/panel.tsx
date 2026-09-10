"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonClass, buttonQuietClass } from "@/components/ui";
import { inviteMember, inviteEveryone, type InviteState } from "../actions";

function Go({ label, busy, quiet }: { label: string; busy: string; quiet?: boolean }) {
  const { pending } = useFormStatus();
  return (
    <button className={quiet ? buttonQuietClass : buttonClass} disabled={pending}>
      {pending ? busy : label}
    </button>
  );
}

/** Everyone who has no account, in one press — the case after an import. */
export function InviteEveryone({ count }: { count: number }) {
  const [state, action] = useFormState<InviteState, FormData>(inviteEveryone, null);
  return (
    <div>
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      {count > 0 && (
        <form action={action}>
          <Go label={`Invite all ${count} who have no account`} busy="Sending…" />
        </form>
      )}
    </div>
  );
}

/** One member — from their own row, or from their own screen. */
export function InviteOne({
  memberId, label = "Send invite", quiet,
}: { memberId: string; label?: string; quiet?: boolean }) {
  const [state, action] = useFormState<InviteState, FormData>(inviteMember, null);
  return (
    <div>
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <form action={action}>
        <input type="hidden" name="member_id" value={memberId} />
        <Go label={label} busy="Sending…" quiet={quiet} />
      </form>
    </div>
  );
}
