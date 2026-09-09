"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, inputClass } from "@/components/ui";
import { saveNote, resolveNote, deleteNote, type RecordState } from "./actions";

export type Note = {
  id: string; category: string; body: string; pinned: boolean;
  managers_only: boolean; active: boolean; created_at: string;
};

const LABEL: Record<string, string> = {
  general: "General", injury: "Injury", medical: "Medical",
  preference: "Preference", admin: "Admin",
};

function Btn({ label, tone = "quiet" }: { label: string; tone?: "quiet" | "primary" | "danger" }) {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
      className={`shrink-0 rounded-lg px-3 py-1.5 text-[12.5px] font-medium disabled:opacity-60 ${
        tone === "primary" ? "bg-ink text-paper" : ""}`}
      style={tone === "danger" ? { color: "var(--coral-deep)" }
           : tone === "quiet" ? { color: "var(--ink-2)" } : undefined}>
      {pending ? "…" : label}
    </button>
  );
}

/**
 * Notes, which have been readable since migration 001 and writable by nothing.
 *
 * PINNED IS WHY THEY EXIST: a pinned note surfaces on the class roster, which
 * is the moment an instructor needs to know about the shoulder. So pinning is a
 * checkbox on the note rather than a separate concept, and resolving takes it
 * off the roster without losing that it happened.
 */
export default function NotesPanel({
  memberId, notes, canSeeManagerOnly,
}: {
  memberId: string; notes: Note[]; canSeeManagerOnly: boolean;
}) {
  const [saveState, save] = useFormState<RecordState, FormData>(saveNote, null);
  const [resState, resolve] = useFormState<RecordState, FormData>(resolveNote, null);
  const [delState, remove] = useFormState<RecordState, FormData>(deleteNote, null);
  const state = saveState ?? resState ?? delState;
  const [adding, setAdding] = useState(false);
  const [editing, setEditing] = useState<string | null>(null);

  const live = notes.filter((n) => n.active);
  const done = notes.filter((n) => !n.active);

  const Form = ({ note }: { note?: Note }) => (
    <form action={save} className="rounded-xl p-3" style={{ background: "var(--paper)" }}>
      <input type="hidden" name="member_id" value={memberId} />
      {note && <input type="hidden" name="note_id" value={note.id} />}
      <textarea name="body" rows={3} required defaultValue={note?.body ?? ""}
                placeholder="What should the studio know?"
                className={`${inputClass} resize-y`} />
      <div className="mt-2 flex flex-wrap items-center gap-3">
        <select name="category" defaultValue={note?.category ?? "general"}
                aria-label="Category"
                className="rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[12.5px] text-ink">
          {Object.entries(LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
        </select>
        <label className="flex items-center gap-1.5 text-[12.5px] text-ink-2">
          <input type="checkbox" name="pinned" defaultChecked={note?.pinned} />
          Pin to the roster
        </label>
        {canSeeManagerOnly && (
          <label className="flex items-center gap-1.5 text-[12.5px] text-ink-2">
            <input type="checkbox" name="managers_only" defaultChecked={note?.managers_only} />
            Managers only
          </label>
        )}
        <span className="ml-auto flex items-center gap-2">
          <Btn label={note ? "Save" : "Add note"} tone="primary" />
          <button type="button" onClick={() => { setAdding(false); setEditing(null); }}
                  className="text-[12.5px] text-ink-3">Cancel</button>
        </span>
      </div>
    </form>
  );

  const Row = ({ n }: { n: Note }) => (
    <li className={`s-row ${n.active ? "" : "opacity-60"}`}>
      {editing === n.id ? <Form note={n} /> : (
        <>
          <div className="flex items-start gap-2">
            <span className="s-tag mt-0.5">{LABEL[n.category] ?? n.category}</span>
            {n.pinned && n.active && (
              <span className="s-tag mt-0.5" style={{ background: "var(--lime-tint)", color: "var(--lime-text)" }}>
                On the roster
              </span>
            )}
            {n.managers_only && (
              <span className="s-tag mt-0.5" style={{ background: "var(--amber-tint)", color: "var(--amber-deep)" }}>
                Managers only
              </span>
            )}
            <span className="ml-auto shrink-0 text-[11px] leading-4 text-ink-3">
              {new Date(n.created_at).toLocaleDateString("en-GB",
                { day: "numeric", month: "short", year: "numeric" })}
            </span>
          </div>
          <p className="mt-1.5 whitespace-pre-wrap text-[13.5px] leading-[21px] text-ink">{n.body}</p>
          <div className="mt-1.5 flex items-center gap-1">
            <button onClick={() => setEditing(n.id)} className="text-[12.5px] text-ink-3">Edit</button>
            <span aria-hidden className="text-ink-3">·</span>
            <form action={resolve} className="inline">
              <input type="hidden" name="member_id" value={memberId} />
              <input type="hidden" name="note_id" value={n.id} />
              {!n.active && <input type="hidden" name="reopen" value="1" />}
              <Btn label={n.active ? "Resolve" : "Reopen"} />
            </form>
            <span aria-hidden className="text-ink-3">·</span>
            <form action={remove} className="inline">
              <input type="hidden" name="member_id" value={memberId} />
              <input type="hidden" name="note_id" value={n.id} />
              <Btn label="Delete" tone="danger" />
            </form>
          </div>
        </>
      )}
    </li>
  );

  return (
    <section className="s-card p-5">
      <div className="mb-3 flex items-center justify-between gap-3">
        <h2 className="s-head">Notes</h2>
        {!adding && (
          <button onClick={() => setAdding(true)} className="text-[12.5px] font-medium text-ink-2">
            Add a note
          </button>
        )}
      </div>
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      {adding && <div className="mb-3"><Form /></div>}

      {live.length === 0 && done.length === 0 && !adding ? (
        <p className="text-[13px] leading-[20px] text-ink-2">
          Nothing yet. A pinned note shows on the class roster, which is where an
          instructor needs to see it.
        </p>
      ) : (
        <ul>{live.map((n) => <Row key={n.id} n={n} />)}</ul>
      )}

      {done.length > 0 && (
        <details className="mt-3">
          <summary className="cursor-pointer text-[12.5px] text-ink-3">
            {done.length} resolved
          </summary>
          <ul className="mt-1">{done.map((n) => <Row key={n.id} n={n} />)}</ul>
        </details>
      )}
    </section>
  );
}
