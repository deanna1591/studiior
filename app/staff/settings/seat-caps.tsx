"use client";

import { useFormState, useFormStatus } from "react-dom";
import Link from "next/link";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveSeatCaps, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Decision 24's first switch, and only its first.
 *
 * Peak allowance and the suspension ladder are separate switches that do not
 * exist yet, and turning this one on must not hint at them. What it does is
 * narrow and complete: it lets a PLAN say how many people it is for.
 *
 * The numbers themselves live on each plan, not here — a studio caps Unlimited
 * Monthly at twelve and leaves the drop-in uncapped, so a studio-wide number
 * would be the wrong shape. This switch only decides whether the plan screen
 * offers the question at all.
 */
export default function SeatCapsPanel({ enabled, capped }: {
  enabled: boolean; capped: number;
}) {
  const [state, action] = useFormState<PlainState, FormData>(saveSeatCaps, null);

  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="seat_caps_enabled" defaultChecked={enabled} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Limit places on a plan</span> — a plan can
            hold only so many members at once, and the desk is stopped from selling
            past it.
            <span className="block text-[12px] leading-[18px] text-ink-3">
              Counts members who hold the plan now, never how many you have ever
              sold. Somebody who cancels frees their place; somebody who freezes
              keeps theirs, and keeps their price.
            </span>
          </span>
        </label>

        {enabled && (
          <p className="mt-3 border-t border-line pt-3 text-[12px] leading-[18px] text-ink-3">
            {capped === 0 ? (
              <>
                No plan has a limit yet, so nothing is capped. Set one on the plan
                itself —{" "}
                <Link href="/plans" className="text-lime-text underline underline-offset-4">
                  your plans
                </Link>
                .
              </>
            ) : (
              <>
                <span className="num">{capped}</span> plan{capped === 1 ? " has" : "s have"} a
                limit. Turning this off leaves those numbers where they are and simply
                stops applying them.
              </>
            )}
          </p>
        )}
      </div>

      <div className="mt-3"><Save /></div>
    </form>
  );
}
