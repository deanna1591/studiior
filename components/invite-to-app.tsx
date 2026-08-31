"use client";

import { useFormState, useFormStatus } from "react-dom";
import { inviteMemberToApp, type InviteState } from "@/app/staff/actions";
import { Notice } from "@/components/ui";

function Submit({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return (
    <button
      disabled={pending}
      className="inline-flex items-center gap-1.5 rounded text-[12px] leading-4 text-ink-2 underline decoration-line-2 underline-offset-4 hover:text-ink disabled:opacity-50"
    >
      {pending ? "Making a link…" : label}
    </button>
  );
}

/**
 * Invite one member to the app.
 *
 * Nothing sends the link — there is no transport, and the studio invite in
 * migration 012 works the same way. The token is shown once because only its
 * hash is kept, so "make me another" is the only recovery and the copy says so.
 */
export default function InviteToApp({
  memberId, label = "Invite to the app",
}: {
  memberId: string; label?: string;
}) {
  const [state, action] = useFormState<InviteState, FormData>(inviteMemberToApp, null);

  return (
    <form action={action}>
      <input type="hidden" name="member_id" value={memberId} />
      {state && !state.ok && <Notice kind="error">{state.message}</Notice>}
      {state?.ok ? (
        <div className="border-l-[3px] px-3 py-2"
             style={{ borderLeftColor: "var(--lime-text)", background: "var(--lime-tint)" }}>
          <p className="text-[13px] leading-[18px] text-ink">{state.message}</p>
          {state.link && (
            <code className="mt-2 block break-all rounded border border-line-2 bg-surface px-2 py-1.5 font-mono text-[11px] leading-4 text-ink">
              {state.link}
            </code>
          )}
          <p className="mt-1.5 text-[11px] leading-4 text-ink-3">
            Copy it now — only a hash of it is stored, so it cannot be shown again.
          </p>
        </div>
      ) : (
        <Submit label={label} />
      )}
    </form>
  );
}
