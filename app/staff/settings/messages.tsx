"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveMessages, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Decision 89 — the one switch for member↔studio messages. Off by default. When
 * on, members get a "Message the studio" option in their app and every
 * non-instructor staff role gets a Messages tab to reply from.
 */
export default function MessagesSettingPanel({ enabled }: { enabled: boolean }) {
  const [state, action] = useFormState<PlainState, FormData>(saveMessages, null);
  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="messages_enabled" defaultChecked={enabled} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Members can message the studio</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              Members get a &ldquo;Message the studio&rdquo; option in their app; owners, managers
              and front desk reply from the Messages tab. Instructors cannot see or send
              messages. Off by default.
            </span>
          </span>
        </label>
        <div className="mt-3"><Save /></div>
      </div>
    </form>
  );
}
