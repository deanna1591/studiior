"use client";

import { useState } from "react";
import { deleteConversation } from "../actions";

/**
 * Decision 89 (a) — a quiet secondary control at the foot of the member header
 * card. One tap reveals the confirm with the exact wording; Delete submits to
 * staff_delete_thread (then the action redirects to the list), Keep dismisses.
 */
export default function DeleteConversation({ threadId, firstName }: { threadId: string; firstName: string }) {
  const [confirming, setConfirming] = useState(false);

  if (!confirming) {
    return (
      <button type="button" onClick={() => setConfirming(true)}
              className="mt-3 text-[12px] text-ink-2 underline underline-offset-2">
        Delete conversation
      </button>
    );
  }

  return (
    <div className="mt-3 rounded border px-3 py-2.5"
         style={{ borderColor: "var(--coral)", background: "var(--coral-tint)" }}>
      <p className="text-[12px] text-ink">Delete this conversation? This removes it for {firstName} too.</p>
      <div className="mt-2 flex gap-2">
        <form action={deleteConversation}>
          <input type="hidden" name="thread_id" value={threadId} />
          <button type="submit" className="rounded px-3 py-1 text-[12px] font-semibold"
                  style={{ background: "var(--coral-deep)", color: "#FFFFFF" }}>
            Delete
          </button>
        </form>
        <button type="button" onClick={() => setConfirming(false)}
                className="rounded border border-line px-3 py-1 text-[12px] font-semibold text-ink">
          Keep
        </button>
      </div>
    </div>
  );
}
