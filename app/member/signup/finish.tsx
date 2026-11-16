"use client";

import { finishSignup, type ClaimState } from "../actions";
import { Note, PrimaryButton, useAuthAction } from "@/components/member/ui";

export default function FinishForm({
  studioId, confirmed,
}: { studioId: string; confirmed: boolean }) {
  const { error, pending, onSubmit } = useAuthAction(finishSignup, "/");
  return (
    <form onSubmit={onSubmit} className="mt-6">
      {error && <Note ok={false}>{error}</Note>}
      <input type="hidden" name="studio_id" value={studioId} />
      {/* Decision 114: ticked by default; unticking sets marketing_opt_in false. */}
      <label className="mb-4 flex items-start gap-2.5 text-[14px] text-ink">
        <input type="checkbox" name="marketing_opt_in" defaultChecked
               className="mt-0.5 h-4 w-4 shrink-0 accent-[var(--accent-solid)]" />
        <span>Send me studio news and offers.</span>
      </label>
      <PrimaryButton pending={pending}>{confirmed ? "Take me in" : "I've confirmed my email"}</PrimaryButton>
      {!confirmed && (
        <p className="m-micro mt-2 text-ink-3">
          We check with the server, so pressing it early just tells you to look
          in your inbox.
        </p>
      )}
    </form>
  );
}
