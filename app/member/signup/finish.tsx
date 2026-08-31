"use client";

import { useFormState } from "react-dom";
import { finishSignup, type ClaimState } from "../actions";
import { Note, PrimaryButton } from "@/components/member/ui";

export default function FinishForm({
  studioId, confirmed,
}: { studioId: string; confirmed: boolean }) {
  const [state, action] = useFormState<ClaimState, FormData>(finishSignup, null);
  return (
    <form action={action} className="mt-6">
      {state && <Note ok={false}>{state.error}</Note>}
      <input type="hidden" name="studio_id" value={studioId} />
      <PrimaryButton>{confirmed ? "Take me in" : "I've confirmed my email"}</PrimaryButton>
      {!confirmed && (
        <p className="m-micro mt-2 text-ink-3">
          We check with the server, so pressing it early just tells you to look
          in your inbox.
        </p>
      )}
    </form>
  );
}
