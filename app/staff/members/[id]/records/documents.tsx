"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice } from "@/components/ui";
import { uploadDocument, deleteDocument, uploadMemberPhoto, type RecordState } from "./actions";

export type Doc = {
  id: string; kind: string; filename: string; storage_path: string;
  size_bytes: number | null; signed_at: string | null; created_at: string;
  /** Signed on the server when the page rendered; short-lived by design. */
  url: string | null;
};

const KIND: Record<string, string> = {
  waiver: "Waiver", medical: "Medical", id: "ID", other: "Other",
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
 * Documents. Chapter 6's MVP scope, never built.
 *
 * The waiver is the one that matters: members.waiver_signed_at has gated §2.1
 * booking since migration 002 with nothing producing the document behind it, so
 * "signed" has meant "somebody ticked it". Filing a signed waiver here sets the
 * timestamp, and the copy says so rather than leaving it to be noticed.
 *
 * Medical documents are managers only — §14 denies instructors a member's
 * contact details and this is the same rule; front desk take waivers at the
 * counter and have no reason to read a diagnosis. Enforced in the policy, not
 * here: this component simply never receives what the caller cannot read.
 */
export default function DocumentsPanel({
  memberId, docs, waiverSignedAt, canDelete,
}: {
  memberId: string; docs: Doc[]; waiverSignedAt: string | null; canDelete: boolean;
}) {
  const [upState, upload] = useFormState<RecordState, FormData>(uploadDocument, null);
  const [delState, remove] = useFormState<RecordState, FormData>(deleteDocument, null);
  const state = upState ?? delState;
  const [adding, setAdding] = useState(false);

  const kb = (n: number | null) => n == null ? "" : `${Math.max(1, Math.round(n / 1024))} KB`;

  return (
    <section className="s-card p-5">
      <div className="mb-3 flex items-center justify-between gap-3">
        <h2 className="s-head">Documents</h2>
        {!adding && (
          <button onClick={() => setAdding(true)} className="text-[12.5px] font-medium text-ink-2">
            Upload
          </button>
        )}
      </div>
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      {/* The waiver's state, said plainly, because it decides whether they can
          book at all. */}
      <p className="mb-3 text-[12.5px] leading-[19px]"
         style={{ color: waiverSignedAt ? "var(--ink-2)" : "var(--coral-deep)" }}>
        {waiverSignedAt
          ? `Waiver signed ${new Date(waiverSignedAt).toLocaleDateString("en-GB",
              { day: "numeric", month: "short", year: "numeric" })}.`
          : "No waiver on file, so they cannot book. Uploading a signed one fixes both at once."}
      </p>

      {adding && (
        <form action={upload} className="mb-3 rounded-xl p-3" style={{ background: "var(--paper)" }}>
          <input type="hidden" name="member_id" value={memberId} />
          <div className="flex flex-wrap items-center gap-2">
            <select name="kind" defaultValue="waiver" aria-label="What kind of document"
                    className="rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[12.5px] text-ink">
              {Object.entries(KIND).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
            </select>
            <input type="file" name="document" required
                   accept="application/pdf,image/png,image/jpeg,image/webp"
                   className="text-[12.5px] text-ink-2" />
            <span className="ml-auto flex items-center gap-2">
              <Btn label="File it" tone="primary" />
              <button type="button" onClick={() => setAdding(false)}
                      className="text-[12.5px] text-ink-3">Cancel</button>
            </span>
          </div>
          <p className="mt-2 text-[11.5px] leading-4 text-ink-3">
            Up to 10 MB, which is the bucket&rsquo;s own ceiling. Stored privately —
            the link below is signed and expires.
          </p>
        </form>
      )}

      {docs.length === 0 ? (
        <p className="text-[13px] leading-[20px] text-ink-2">
          Nothing on file yet.
        </p>
      ) : (
        <ul>
          {docs.map((d) => (
            <li key={d.id} className="s-row flex items-center gap-3">
              <span className="s-tag shrink-0">{KIND[d.kind] ?? d.kind}</span>
              <span className="min-w-0 flex-1">
                <span className="block truncate text-[13.5px] leading-5 text-ink">{d.filename}</span>
                <span className="block text-[11.5px] leading-4 text-ink-3">
                  {new Date(d.created_at).toLocaleDateString("en-GB",
                    { day: "numeric", month: "short", year: "numeric" })}
                  {d.size_bytes ? ` · ${kb(d.size_bytes)}` : ""}
                </span>
              </span>
              {d.url && (
                <a href={d.url} target="_blank" rel="noreferrer"
                   className="shrink-0 text-[12.5px] font-medium text-ink-2">
                  Open
                </a>
              )}
              {canDelete && (
                <form action={remove} className="shrink-0">
                  <input type="hidden" name="member_id" value={memberId} />
                  <input type="hidden" name="document_id" value={d.id} />
                  <input type="hidden" name="path" value={d.storage_path} />
                  <Btn label="Remove" tone="danger" />
                </form>
              )}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

/**
 * The photo, uploaded by the desk.
 *
 * A walk-in signing up at the counter is exactly the person who will not upload
 * their own, and until now only the member could: member-avatars was readable
 * by staff and writable only by its owner.
 */
export function PhotoUpload({ memberId, name, url }: {
  memberId: string; name: string; url: string | null;
}) {
  const [state, action] = useFormState<RecordState, FormData>(uploadMemberPhoto, null);
  const initials = name.split(/\s+/).filter(Boolean).slice(0, 2)
    .map((w) => w[0]?.toUpperCase() ?? "").join("") || "?";

  return (
    <div className="flex items-center gap-4">
      {url ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={url} alt="" aria-hidden
             className="h-16 w-16 shrink-0 rounded-full object-cover"
             style={{ boxShadow: "0 1px 3px rgb(26 21 18 / 0.12)" }} />
      ) : (
        <span aria-hidden
              className="flex h-16 w-16 shrink-0 items-center justify-center rounded-full text-[19px] font-semibold"
              style={{ background: "var(--paper)", color: "var(--ink-2)",
                       boxShadow: "inset 0 0 0 1px var(--line)" }}>
          {initials}
        </span>
      )}
      <form action={action} className="min-w-0">
        <input type="hidden" name="member_id" value={memberId} />
        {/* The raw file input is hidden and the label is the control. A bare
            "Choose File / No file chosen" beside somebody's face is the browser
            showing through the design. */}
        <label className="inline-flex cursor-pointer items-center rounded-lg px-3 py-1.5 text-[12.5px] font-medium"
               style={{ background: "var(--paper)", color: "var(--ink-2)" }}>
          {url ? "Replace photo" : "Add a photo"}
          <input type="file" name="photo" accept="image/png,image/jpeg,image/webp"
                 className="sr-only"
                 onChange={(e) => e.currentTarget.form?.requestSubmit()} />
        </label>
        {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      </form>
    </div>
  );
}
