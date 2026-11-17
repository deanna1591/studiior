"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveWeeklyCampaigns, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/** Decision 112 — weekly campaigns by audience. Off by default; gated by
 *  marketing consent. Turning it on seeds the three starting audiences. */
export default function WeeklyCampaignsPanel({ enabled }: { enabled: boolean }) {
  const [state, action] = useFormState<PlainState, FormData>(saveWeeklyCampaigns, null);
  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="weekly_campaigns_enabled" defaultChecked={enabled} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Send weekly campaign emails by audience</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              Once a week we email the members in each audience a short message — a nudge to come
              back, try a new class, or pick a plan. Only members who said yes to news are emailed,
              never more than once in three days, and each person stops after their audience's limit.
              Off by default. Set up your audiences on the Campaigns page.
            </span>
          </span>
        </label>
        <div className="mt-3"><Save /></div>
      </div>
    </form>
  );
}
