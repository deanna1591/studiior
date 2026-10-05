"use client";

import { useFormState, useFormStatus } from "react-dom";
import { SectionLabel } from "@/components/ui";
import { inviteLogin, removeLogin, type LoginState } from "./login-actions";

type Login = { email: string; signedInLabel: string | null } | null;

function Btn({ label, busy, danger = false }: { label: string; busy: string; danger?: boolean }) {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
            className={`shrink-0 rounded px-2.5 py-1.5 text-[12px] font-medium leading-4 disabled:opacity-50 ${
              danger
                ? "border border-[color:var(--coral)] text-ink hover:bg-[color:var(--coral-tint)]"
                : "bg-ink text-paper hover:bg-ink-2"}`}>
      {pending ? busy : label}
    </button>
  );
}

function Message({ state }: { state: LoginState }) {
  if (!state) return null;
  return (
    <p className="mt-2 text-[12px] leading-[17px] text-ink-2"
       role={"error" in state ? "alert" : "status"}
       style={"error" in state ? { borderLeft: "3px solid var(--coral)", paddingLeft: 8 } : undefined}>
      {"error" in state ? state.error : state.ok}
    </p>
  );
}

/**
 * Decision 64 — the instructor's app login: the line + Remove when they have one,
 * the Invite form when they do not.
 */
export default function LoginPanel({
  instructorId, email, login,
}: { instructorId: string; email: string | null; login: Login }) {
  const [removeState, remove] = useFormState<LoginState, FormData>(removeLogin, null);
  const [inviteState, invite] = useFormState<LoginState, FormData>(inviteLogin, null);

  return (
    <div className="mt-8 max-w-md">
      <SectionLabel>App login</SectionLabel>
      {login ? (
        <div className="mt-2">
          <p className="text-[14px] leading-5 text-ink">{login.email}</p>
          <p className="text-[12px] leading-4 text-ink-3">
            {login.signedInLabel ? `Signed in ${login.signedInLabel}` : "Invited — never signed in"}
          </p>
          <form action={remove} className="mt-2">
            <input type="hidden" name="instructor_id" value={instructorId} />
            <Btn label="Remove app login" busy="Removing…" danger />
            <p className="mt-1.5 text-[12px] leading-[17px] text-ink-3">
              {login.email} will no longer be able to sign in as this instructor. Their
              classes, availability, pay and history stay. You can invite them again
              afterwards with any email.
            </p>
          </form>
          <Message state={removeState} />
        </div>
      ) : (
        <div className="mt-2">
          <p className="text-[13px] leading-5 text-ink-2">No app login yet.</p>
          <form action={invite} className="mt-2 flex flex-wrap items-center gap-2">
            <input type="hidden" name="instructor_id" value={instructorId} />
            <input name="email" type="email" required defaultValue={email ?? ""}
                   placeholder="their email"
                   className="w-[210px] rounded border border-line-2 bg-surface px-2 py-1.5 text-[13px] text-ink placeholder:text-ink-3" />
            <Btn label="Invite" busy="Sending…" />
          </form>
          <p className="mt-1.5 text-[12px] leading-[17px] text-ink-3">
            Sends a one-time link that lasts fourteen days, so they can sign in to the
            instructor app and see their own schedule.
          </p>
          <Message state={inviteState} />
        </div>
      )}
    </div>
  );
}
