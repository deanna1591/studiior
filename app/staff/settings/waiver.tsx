"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveWaiver, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Publishing…" : "Publish new version"}</button>;
}

/**
 * Decision 34 — the studio's waiver, as versioned text or an uploaded PDF. A new
 * version supersedes; it never edits the old one. "Require members to sign again"
 * re-gates booking for everyone until they re-sign; leave it off and existing
 * signatures stand.
 */
export default function WaiverPanel({
  current,
}: {
  current: { format: string; requires_resign: boolean; created_at: string; body: string | null } | null;
}) {
  const [state, action] = useFormState<PlainState, FormData>(saveWaiver, null);
  const [format, setFormat] = useState<"text" | "pdf">("text");

  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      <div className="rounded border border-line bg-surface px-3.5 py-3">
        {current ? (
          <p className="mb-3 text-[12px] leading-[18px] text-ink-3">
            Current version: <span className="font-medium text-ink-2">{current.format.toUpperCase()}</span>
            {current.requires_resign && " · re-sign required"} · published {new Date(current.created_at).toLocaleDateString()}.
            Members sign this one; publishing below supersedes it.
          </p>
        ) : (
          <p className="mb-3 text-[12px] leading-[18px] text-ink-3">
            No waiver yet. Until you publish one, members with <span className="font-medium">Require waiver</span> on
            cannot sign in the app.
          </p>
        )}

        <div className="mb-3 flex gap-4 text-[13px] text-ink">
          <label className="flex items-center gap-1.5">
            <input type="radio" name="format" value="text" checked={format === "text"}
                   onChange={() => setFormat("text")} /> Text
          </label>
          <label className="flex items-center gap-1.5">
            <input type="radio" name="format" value="pdf" checked={format === "pdf"}
                   onChange={() => setFormat("pdf")} /> PDF
          </label>
        </div>

        {format === "text" ? (
          <textarea name="body" rows={10}
                    defaultValue={current?.format === "text" ? current.body ?? "" : ""}
                    placeholder="Paste or write your waiver here. Members read the whole thing before signing."
                    className="w-full rounded border border-line bg-surface px-3 py-2 text-[13px] leading-[19px] text-ink" />
        ) : (
          <input type="file" name="pdf" accept="application/pdf"
                 className="block w-full text-[13px] text-ink-2" />
        )}

        <label className="mt-3 flex items-start gap-2.5 border-t border-line pt-3">
          <input type="checkbox" name="requires_resign" className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Require members to sign this version</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              Everyone must sign the new version before they can book again. Leave off for a minor
              wording change — existing signatures keep standing.
            </span>
          </span>
        </label>

        <div className="mt-3"><Save /></div>
      </div>
    </form>
  );
}
