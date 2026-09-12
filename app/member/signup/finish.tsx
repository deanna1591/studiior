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
