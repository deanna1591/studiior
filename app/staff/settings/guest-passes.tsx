"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveGuestPasses, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Decision 26's switch — the door. Off by default: a studio that never turns it
 * on shows no "bring a guest" option in the member app and no guest column
 * anywhere. On, a member can bring one friend to the class they are booking, and
 * that friend's first class is free. Turning it back off never removes a guest
 * already booked — their seat is an ordinary booking that stands on its own.
 */
export default function GuestPassesPanel({ enabled }: { enabled: boolean }) {
  const [state, action] = useFormState<PlainState, FormData>(saveGuestPasses, null);

  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="guest_passes_enabled" defaultChecked={enabled} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Let members bring a guest</span> — a member invites
            a friend to the class they are booking, and the friend&rsquo;s first class is free.
            <span className="block text-[12px] leading-[18px] text-ink-3">
              One free class per person, ever. The guest signs the waiver in the app before
              the class, and becomes an ordinary member afterwards. A member can bring another
              guest once their current one has come.
            </span>
          </span>
        </label>

        <div className="mt-3"><Save /></div>
      </div>
    </form>
  );
}
