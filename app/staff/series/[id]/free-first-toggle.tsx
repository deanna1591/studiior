"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice } from "@/components/ui";
import { setSeriesFreeFirst } from "../actions";

function Save() {
  const { pending } = useFormStatus();
  return (
    <button className="rounded border border-line-2 bg-surface px-2.5 py-1 text-[12px] text-ink-2 disabled:opacity-60"
            disabled={pending}>{pending ? "Saving…" : "Save"}</button>
  );
}

/**
 * Decision 30 amendment: whether this recurring class accepts free first classes.
 * Shown only when the studio runs free first classes; default on.
 */
export default function FreeFirstToggle({ seriesId, allowed }: { seriesId: string; allowed: boolean }) {
  const [state, action] = useFormState<{ ok: boolean; message: string } | null, FormData>(setSeriesFreeFirst, null);
  return (
    <form action={action} className="mb-6 max-w-xl rounded border border-line bg-surface px-3.5 py-3">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <input type="hidden" name="series_id" value={seriesId} />
      <label className="flex items-start gap-2.5">
        <input type="checkbox" name="free_first_allowed" defaultChecked={allowed} className="mt-1" />
        <span className="text-[13px] leading-[19px] text-ink">
          <span className="font-medium">Accepts free first classes</span>
          <span className="block text-[12px] leading-[18px] text-ink-3">
            New members may book this recurring class as their free first class. Turn it off to keep
            free seats off this class; your other classes are unaffected.
          </span>
        </span>
      </label>
      <div className="mt-2.5"><Save /></div>
    </form>
  );
}
