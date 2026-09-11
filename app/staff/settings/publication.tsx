"use client";

import Link from "next/link";
import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { savePublication, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Decision 25's switch. Off by default; a studio that never turns it on sees
 * no draft state, no Publish screen, no month gate and no roster email.
 *
 * The consequence is said HERE, before the box is ticked: the moment this is
 * on, a month members cannot see is a month they cannot book, and the only
 * thing that makes a month visible is publishing it. This month and any month
 * already booked into are published automatically on the way on, and the
 * saved message names them.
 */
export default function PublicationPanel({ enabled, publishedMonths, nextDraft }: {
  enabled: boolean;
  /** Labels of the months currently published, for the line under the box. */
  publishedMonths: string[];
  /** The first month from now that is still a draft, or null. */
  nextDraft: string | null;
}) {
  const [state, action] = useFormState<PlainState, FormData>(savePublication, null);
  const [on, setOn] = useState(enabled);

  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="publication_enabled" defaultChecked={enabled}
                 onChange={(e) => setOn(e.currentTarget.checked)} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">A month is a draft until you publish it</span> — members
            cannot see or book a month you have not published, and instructors are not
            shown it or told about it until you do.
            <span className="block text-[12px] leading-[18px] text-ink-3">
              Members can only book as far as the published month: nobody can book December
              until December is published. This month, and any month members have already
              booked into, are published the moment you turn this on.
            </span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              Publishing sends each instructor their own classes for the month to confirm.
              A published month cannot be taken back.
            </span>
          </span>
        </label>

        {on && enabled && (
          <p className="mt-3 border-t border-line pt-3 text-[12px] leading-[18px] text-ink-2">
            {publishedMonths.length === 0
              ? "Nothing is published yet, so members cannot book anything. "
              : <>Published: {publishedMonths.join(", ")}. </>}
            {nextDraft && <>{nextDraft} is still a draft. </>}
            <Link href="/publish" className="underline underline-offset-4">Publish a month</Link>
          </p>
        )}

        <div className="mt-3"><Save /></div>
      </div>
    </form>
  );
}
