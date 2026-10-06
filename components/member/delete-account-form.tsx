"use client";

import { useState, useTransition } from "react";
import { isDeleteConfirmed } from "@/lib/account-delete";
import { deleteMyAccount } from "@/app/member/account/delete/actions";

/**
 * Decision 69 — the confirmation step. Type DELETE, then the destructive button.
 * On success the account is gone, so this navigates with a full-document load to
 * the public "deleted" page (no session left to render a member screen).
 */
export default function DeleteAccountForm({ contactEmail }: { contactEmail: string | null }) {
  const [typed, setTyped] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [showContact, setShowContact] = useState(false);
  const [pending, start] = useTransition();
  const armed = isDeleteConfirmed(typed);

  function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!armed || pending) return;
    setError(null); setShowContact(false);
    start(async () => {
      const res = await deleteMyAccount(typed);
      if ("ok" in res) { window.location.assign("/account/deleted"); return; }
      setError(res.error);
      setShowContact(res.contact === true);
    });
  }

  return (
    <form onSubmit={onSubmit} className="mt-6">
      <label htmlFor="confirm" className="m-sub block text-ink-2">
        Type <span className="font-semibold text-ink">DELETE</span> to confirm.
      </label>
      <input
        id="confirm" name="confirm" autoComplete="off" autoCapitalize="characters"
        value={typed} onChange={(e) => setTyped(e.target.value)}
        className="m-tap mt-2 w-full rounded-xl border border-line-2 bg-surface px-3.5 text-[16px] text-ink outline-none"
        placeholder="DELETE"
      />

      {error && (
        <p className="m-sub mt-3 rounded-lg px-3 py-2 text-ink" role="alert"
           style={{ borderLeft: "3px solid var(--coral)", background: "var(--coral-tint)" }}>
          {error}
          {showContact && contactEmail && (
            <> <a href={`mailto:${contactEmail}`} className="underline underline-offset-2">{contactEmail}</a></>
          )}
        </p>
      )}

      <button
        type="submit" disabled={!armed || pending}
        className="m-action m-press mt-4 flex w-full items-center justify-center rounded-xl text-[16px] font-semibold disabled:opacity-50"
        style={{ background: "var(--coral-deep)", color: "#FFFFFF" }}
      >
        {pending ? "Deleting…" : "Delete my account"}
      </button>
    </form>
  );
}
