"use client";

import { useEffect, useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { validateGroupEmails } from "@/lib/group";
import { bookGroupAction, swapGuestAction, cancelGroupAction, type GroupActionState } from "./actions";

function Submitting({ label, busy }: { label: string; busy: string }) {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
            style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
            className="m-action m-press flex w-full items-center justify-center rounded-xl text-[16px] font-semibold disabled:opacity-60">
      {pending ? busy : label}
    </button>
  );
}

/**
 * The emails screen — group_size − 1 fields, the host shown as seat one.
 * Client-side validation (distinct, not the host, all filled) is the pure
 * validateGroupEmails; the one thing only the server knows — a member already
 * booked on that class — comes back from book_group by name.
 */
export function EmailsForm({ groupId, occId, hostEmail, groupSize, doneHref }: {
  groupId: string; occId: string; hostEmail: string; groupSize: number; doneHref: string;
}) {
  const [state, action] = useFormState<GroupActionState, FormData>(bookGroupAction, null);
  const [emails, setEmails] = useState<string[]>(Array(groupSize - 1).fill(""));
  const check = validateGroupEmails(emails, hostEmail, groupSize);
  const clientError =
    !check.ok && check.reason === "is_host" ? "That's your own email — you're already seat one."
    : !check.ok && check.reason === "duplicate" ? "Two guests have the same email."
    : null;

  useEffect(() => { if (state?.ok) window.location.assign(doneHref); }, [state, doneHref]);

  return (
    <form action={action} className="space-y-3">
      <input type="hidden" name="group_id" value={groupId} />
      <input type="hidden" name="occurrence_id" value={occId} />
      <div className="m-card p-3">
        <p className="m-micro text-ink-3">Seat 1 — you</p>
        <p className="text-[14px] leading-5 text-ink">{hostEmail}</p>
      </div>
      {emails.map((v, i) => (
        <label key={i} className="block">
          <span className="m-micro text-ink-3">Guest {i + 1}&rsquo;s email</span>
          <input type="email" name="email" value={v} required
                 onChange={(e) => setEmails(emails.map((x, j) => (j === i ? e.target.value : x)))}
                 placeholder="name@example.com"
                 className="mt-1 w-full rounded-xl border border-line bg-surface px-3 py-2.5 text-[15px] text-ink" />
        </label>
      ))}
      {clientError && <p className="m-sub text-coral">{clientError}</p>}
      {state && !state.ok && state.error && <p className="m-sub text-coral">{state.error}</p>}
      <Submitting label={`Book all ${groupSize}`} busy="Booking…" />
    </form>
  );
}

/** Swap one guest for another (until the cut-off). */
export function SwapForm({ groupId, oldEmail }: { groupId: string; oldEmail: string }) {
  const [state, action] = useFormState<GroupActionState, FormData>(swapGuestAction, null);
  const [open, setOpen] = useState(false);
  useEffect(() => { if (state?.ok) window.location.reload(); }, [state]);
  if (!open) {
    return (
      <button onClick={() => setOpen(true)}
              className="m-press text-[13px] text-ink-2 underline underline-offset-4">Swap</button>
    );
  }
  return (
    <form action={action} className="mt-2 flex items-center gap-2">
      <input type="hidden" name="group_id" value={groupId} />
      <input type="hidden" name="old_email" value={oldEmail} />
      <input type="email" name="new_email" required placeholder="new email"
             className="min-w-0 flex-1 rounded-lg border border-line bg-surface px-2.5 py-1.5 text-[14px] text-ink" />
      <SwapSubmit />
      {state && !state.ok && state.error && <span className="m-sub text-coral">{state.error}</span>}
    </form>
  );
}
function SwapSubmit() {
  const { pending } = useFormStatus();
  return <button disabled={pending} className="m-press shrink-0 rounded-lg border border-line px-3 py-1.5 text-[13px] text-ink">{pending ? "…" : "Save"}</button>;
}

/** Cancel the whole group, with the early/late explanation shown first. */
export function CancelGroupForm({ groupId, late }: { groupId: string; late: boolean }) {
  const [state, action] = useFormState<GroupActionState, FormData>(cancelGroupAction, null);
  const [confirm, setConfirm] = useState(false);
  useEffect(() => { if (state?.ok) window.location.assign("/account"); }, [state]);
  if (!confirm) {
    return (
      <button onClick={() => setConfirm(true)}
              className="m-press mt-2 text-[13px] text-coral underline underline-offset-4">
        Cancel this group
      </button>
    );
  }
  return (
    <form action={action} className="mt-3 rounded-xl border-l-2 border-coral bg-coral-tint p-3">
      <input type="hidden" name="group_id" value={groupId} />
      <p className="text-[13px] leading-[18px] text-ink">
        {late
          ? "It's inside the cancellation notice period, so this group is forfeited — no refund, and it can't be rebooked."
          : "Everyone's seat is released and the package goes back to unbooked — you can book it into another class within its window."}
      </p>
      <div className="mt-3 flex items-center gap-3">
        <CancelSubmit />
        <button onClick={() => setConfirm(false)} type="button"
                className="m-press text-[13px] text-ink-2 underline underline-offset-4">Keep it</button>
      </div>
      {state && !state.ok && state.error && <p className="m-sub mt-1 text-coral">{state.error}</p>}
    </form>
  );
}
function CancelSubmit() {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
            className="m-press rounded-xl bg-coral px-4 py-2 text-[14px] font-semibold text-paper disabled:opacity-60">
      {pending ? "Cancelling…" : "Yes, cancel the group"}
    </button>
  );
}
