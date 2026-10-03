"use client";

import { useState, useTransition } from "react";
import { cancelCampaign, duplicateCampaign } from "./actions";

/** Cancel (scheduled only) and Duplicate, for a non-draft campaign. */
export default function CampaignControls({ id, canCancel }: { id: string; canCancel: boolean }) {
  const [pending, startTransition] = useTransition();
  const [err, setErr] = useState<string | null>(null);

  return (
    <div className="mt-5 flex flex-wrap items-center gap-2">
      {canCancel && (
        <button type="button" disabled={pending}
          onClick={() => startTransition(async () => {
            setErr(null);
            const r = await cancelCampaign(id);
            if ("error" in r) setErr(r.error);
          })}
          className="rounded border border-line-2 bg-surface px-3 py-2 text-[13px] font-medium text-ink hover:bg-paper disabled:opacity-50">
          Cancel this campaign
        </button>
      )}
      <button type="button" disabled={pending}
        onClick={() => startTransition(() => duplicateCampaign(id))}
        className="rounded border border-line-2 bg-surface px-3 py-2 text-[13px] font-medium text-ink hover:bg-paper disabled:opacity-50">
        Duplicate
      </button>
      {err && <span className="text-[13px] text-coral">{err}</span>}
    </div>
  );
}
