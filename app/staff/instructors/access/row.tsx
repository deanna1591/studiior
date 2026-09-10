"use client";

import { useFormState, useFormStatus } from "react-dom";
import { sendInstructorInvite, type InviteState } from "./actions";

type Row = {
  id: string; display_name: string; email: string | null;
  state: "signed_in" | "invited" | "invite_expired" | "no_email" | "never_asked";
  expires_at: string | null; invited_at: string | null;
};

const SAYS: Record<Row["state"], string> = {
  signed_in: "Signed in",
  invited: "Invited, not claimed yet",
  invite_expired: "Invite expired",
  no_email: "No email — cannot be invited",
  never_asked: "Never asked",
};

function Send({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
            className="shrink-0 rounded bg-ink px-2.5 py-1.5 text-[12px] font-medium leading-4 text-paper hover:bg-ink-2 disabled:opacity-50">
      {pending ? "Sending…" : label}
    </button>
  );
}

export default function InviteRow({ row }: { row: Row }) {
  const [state, action] = useFormState<InviteState, FormData>(sendInstructorInvite, null);
  const done = row.state === "signed_in";

  return (
    <div className="border-y border-line bg-surface px-3 py-3 first:border-t last:border-b">
      <div className="flex flex-wrap items-baseline gap-x-4 gap-y-1">
        <span className="min-w-[150px] flex-1">
          <span className="block text-[14px] font-medium leading-5 text-ink">{row.display_name}</span>
          <span className="block text-[12px] leading-4 text-ink-3">
            {SAYS[row.state]}
            {row.email ? ` · ${row.email}` : ""}
          </span>
        </span>

        {!done && (
          <form action={action} className="flex flex-wrap items-center gap-2">
            <input type="hidden" name="instructor_id" value={row.id} />
            <input
              name="email" type="email" required defaultValue={row.email ?? ""}
              placeholder="their email"
              className="w-[210px] rounded border border-line-2 bg-surface px-2 py-1.5 text-[13px] text-ink placeholder:text-ink-3"
            />
            <Send label={row.state === "never_asked" || row.state === "no_email" ? "Invite" : "Resend"} />
          </form>
        )}
      </div>

      {state && (
        <p className="mt-1.5 text-[12px] leading-[17px] text-ink-2"
           role={"error" in state ? "alert" : "status"}
           style={"error" in state
             ? { borderLeft: "3px solid var(--coral)", paddingLeft: 8 } : undefined}>
          {"error" in state ? state.error : state.ok}
        </p>
      )}
      {/* A resend kills the previous link. Said, because somebody who has
          forwarded the first one needs to know. */}
      {!done && row.state === "invited" && (
        <p className="mt-1 text-[11px] leading-4 text-ink-3">
          Sending again replaces the link they already have.
        </p>
      )}
    </div>
  );
}
