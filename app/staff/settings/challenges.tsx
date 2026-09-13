"use client";

import Link from "next/link";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveChallenges, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * The challenges switch — the door. Off by default: a studio that never turns
 * it on has no Challenges menu item and no way in, which is what keeps the
 * feature absent for a studio that does not use it. On, it appears in the menu
 * and leads to the create screen. Members see a challenge only once it is
 * published, so this is the staff entry point, not what members are shown.
 */
export default function ChallengesPanel({ enabled, hasChallenges }: {
  enabled: boolean;
  hasChallenges: boolean;
}) {
  const [state, action] = useFormState<PlainState, FormData>(saveChallenges, null);

  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="challenges_enabled" defaultChecked={enabled} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Run challenges</span> — members opt into a goal
            (a number of classes, a weekly streak), and their qualifying attendance counts
            from the start date.
            <span className="block text-[12px] leading-[18px] text-ink-3">
              Recognition, not competition: a member always sees their own progress, and a
              leaderboard is off unless you turn it on for a given challenge. Rewards are
              your own text, fulfilled by you — nothing here is money owed.
            </span>
          </span>
        </label>

        {enabled && (
          <p className="mt-3 border-t border-line pt-3 text-[12px] leading-[18px] text-ink-2">
            {hasChallenges
              ? <>Challenges is in your menu. <Link href="/challenges" className="underline underline-offset-4">Open it</Link>.</>
              : <><Link href="/challenges/new" className="underline underline-offset-4">Create your first challenge</Link> — members can join it the moment you publish.</>}
          </p>
        )}

        <div className="mt-3"><Save /></div>
      </div>
    </form>
  );
}
