"use client";

import { useState, useEffect } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice } from "@/components/ui";
import {
  searchMergeTargets, mergePreview, mergeMembers, deleteMember,
  type DangerState,
} from "./danger-actions";

type Target = { id: string; name: string; email: string };
type Preview = Awaited<ReturnType<typeof mergePreview>>;

function Submit({ label, busy, danger }: { label: string; busy: string; danger?: boolean }) {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
      className={danger
        ? "rounded-lg px-3 py-1.5 text-[13px] font-medium text-paper disabled:opacity-50"
        : "rounded-lg bg-ink px-3 py-1.5 text-[13px] font-medium text-paper disabled:opacity-50"}
      style={danger ? { background: "var(--coral-deep)" } : undefined}>
      {pending ? busy : label}
    </button>
  );
}

/**
 * Decision 97: a manager deletes a member, or merges this (duplicate) member
 * into another. Both are typed-confirmation flows. Merge: search the member to
 * KEEP, see what moves, type their first name. Delete: type this member's first
 * name. On success the page navigates (a full load so the list refreshes).
 */
export default function MemberDangerZone({
  memberId, firstName, studioId, suggested = null,
}: { memberId: string; firstName: string; studioId: string; suggested?: Target | null }) {
  const [open, setOpen] = useState<null | "merge" | "delete">(null);

  return (
    <section id="danger" className="mt-8 rounded-xl border border-line bg-surface px-3.5 py-3">
      <p className="text-[11px] uppercase leading-4 tracking-[0.06em] text-ink-3">Danger zone</p>
      {open === null && suggested && (
        <p className="mt-2 max-w-[60ch] text-[12.5px] leading-[18px] text-ink-2">
          This member looks like <strong>{suggested.name}</strong> ({suggested.email}).
          Merge is preselected below.
        </p>
      )}
      {open === null && (
        <div className="mt-2 flex flex-wrap gap-2">
          <button onClick={() => setOpen("merge")}
            className="rounded-lg border border-line-2 px-3 py-1.5 text-[13px] text-ink-2 hover:text-ink">
            Merge into another member
          </button>
          <button onClick={() => setOpen("delete")}
            className="rounded-lg border border-line-2 px-3 py-1.5 text-[13px] hover:bg-paper"
            style={{ color: "var(--coral-deep)" }}>
            Delete member
          </button>
        </div>
      )}
      {open === "merge" && (
        <MergeFlow memberId={memberId} firstName={firstName} studioId={studioId}
          initialKeep={suggested} onCancel={() => setOpen(null)} />
      )}
      {open === "delete" && (
        <DeleteFlow memberId={memberId} firstName={firstName} onCancel={() => setOpen(null)} />
      )}
    </section>
  );
}

function MergeFlow({
  memberId, firstName, studioId, onCancel, initialKeep = null,
}: { memberId: string; firstName: string; studioId: string; onCancel: () => void; initialKeep?: Target | null }) {
  const [q, setQ] = useState("");
  const [targets, setTargets] = useState<Target[]>([]);
  const [keep, setKeep] = useState<Target | null>(null);
  const [preview, setPreview] = useState<Preview | null>(null);
  const [state, action] = useFormState<DangerState, FormData>(mergeMembers, null);

  // Decision 98: when opened from the "Possible duplicate" chip, preselect the
  // suggested member to keep and load its preview once.
  useEffect(() => {
    if (initialKeep && !keep) {
      setKeep(initialKeep);
      mergePreview(initialKeep.id, memberId).then(setPreview);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function runSearch(term: string) {
    setQ(term);
    if (term.trim().length < 2) { setTargets([]); return; }
    setTargets(await searchMergeTargets(studioId, memberId, term));
  }
  async function pick(t: Target) {
    setKeep(t);
    setPreview(await mergePreview(t.id, memberId));
  }

  if (state?.ok && state.href) {
    if (typeof window !== "undefined") window.location.assign(state.href);
  }

  return (
    <div className="mt-3">
      <p className="mb-2 max-w-[60ch] text-[13px] leading-[19px] text-ink-2">
        Everything from <strong>{firstName}</strong> moves onto the member you keep.
        {firstName} is then closed and shown as merged. This cannot be undone.
      </p>
      {!keep ? (
        <>
          <input value={q} onChange={(e) => runSearch(e.target.value)} autoFocus
            placeholder="Search the member to keep by name or email"
            className="w-full max-w-[42ch] rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink" />
          {targets.length > 0 && (
            <ul className="mt-2 max-w-[42ch] divide-y divide-line rounded-lg border border-line">
              {targets.map((t) => (
                <li key={t.id}>
                  <button onClick={() => pick(t)}
                    className="flex w-full flex-col items-start px-3 py-2 text-left hover:bg-paper">
                    <span className="text-[13px] text-ink">{t.name}</span>
                    <span className="text-[12px] text-ink-3">{t.email}</span>
                  </button>
                </li>
              ))}
            </ul>
          )}
          <button onClick={onCancel} className="mt-2 text-[12.5px] text-ink-2 underline underline-offset-4">Cancel</button>
        </>
      ) : preview && !preview.ok ? (
        <>
          <Notice kind="error">This merge is not allowed: {preview.reason}.</Notice>
          <button onClick={() => { setKeep(null); setPreview(null); }}
            className="mt-2 text-[12.5px] text-ink-2 underline underline-offset-4">Pick someone else</button>
        </>
      ) : preview ? (
        <form action={action}>
          {state && !state.ok && <Notice kind="error">{state.message}</Notice>}
          <div className="mb-3 rounded-lg border border-line bg-paper px-3 py-2.5 text-[13px] leading-[20px] text-ink-2">
            <p className="text-ink">Keep <strong>{preview.keep_name}</strong> ({preview.keep_email}).</p>
            <p className="mt-1">Moves from {firstName}: <span className="num">{preview.counts.bookings}</span> bookings,{" "}
              <span className="num">{preview.counts.payments}</span> payments,{" "}
              <span className="num">{preview.counts.credits}</span> credit rows,{" "}
              <span className="num">{preview.counts.passes}</span> passes,{" "}
              <span className="num">{preview.counts.check_ins}</span> check-ins,{" "}
              <span className="num">{preview.counts.messages}</span> messages.</p>
            {preview.two_active && (
              <p className="mt-1" style={{ color: "var(--amber-deep)" }}>
                Both have an active membership. Both are kept, so check for a duplicate charge.
              </p>
            )}
            <p className="mt-1">The email that stays is <strong>{preview.keep_email}</strong>.</p>
          </div>
          <input type="hidden" name="keep_id" value={keep.id} />
          <input type="hidden" name="remove_id" value={memberId} />
          <input type="hidden" name="keep_name" value={preview.keep_name} />
          <label className="block max-w-[42ch] text-[12.5px] leading-4 text-ink-2">
            <span className="mb-1 block">Type <strong>{preview.keep_name}</strong> to confirm</span>
            <input name="confirm_name" autoFocus autoComplete="off"
              className="w-full rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink" />
          </label>
          <div className="mt-2.5 flex items-center gap-2">
            <Submit label={`Merge ${firstName} into ${preview.keep_name}`} busy="Merging…" />
            <button type="button" onClick={() => { setKeep(null); setPreview(null); }}
              className="text-[12.5px] text-ink-2 underline underline-offset-4">Back</button>
          </div>
        </form>
      ) : (
        <p className="text-[13px] text-ink-3">Loading…</p>
      )}
    </div>
  );
}

function DeleteFlow({
  memberId, firstName, onCancel,
}: { memberId: string; firstName: string; onCancel: () => void }) {
  const [state, action] = useFormState<DangerState, FormData>(deleteMember, null);
  if (state?.ok && state.href) {
    if (typeof window !== "undefined") window.location.assign(state.href);
  }
  return (
    <form action={action} className="mt-3">
      {state && !state.ok && <Notice kind="error">{state.message}</Notice>}
      <p className="mb-2.5 max-w-[60ch] text-[13px] leading-[19px] text-ink-2">
        <strong>{firstName}</strong> leaves the Members list and their login is removed. Their
        bookings, payments and attendance stay on record as a deleted member. Future bookings are
        cancelled with no penalty. This cannot be undone.
      </p>
      <input type="hidden" name="member_id" value={memberId} />
      <input type="hidden" name="first_name" value={firstName} />
      <label className="block max-w-[42ch] text-[12.5px] leading-4 text-ink-2">
        <span className="mb-1 block">Type <strong>{firstName}</strong> to confirm</span>
        <input name="confirm_name" autoFocus autoComplete="off"
          className="w-full rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink" />
      </label>
      <div className="mt-2.5 flex items-center gap-2">
        <Submit label="Delete member" busy="Deleting…" danger />
        <button type="button" onClick={onCancel}
          className="text-[12.5px] text-ink-2 underline underline-offset-4">Cancel</button>
      </div>
    </form>
  );
}
