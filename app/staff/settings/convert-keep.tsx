"use client";

import { useFormStatus } from "react-dom";
import { useFormState } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveConvertKeep, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Decision 78 — "Convert and keep". Off by default. When on, a new member who
 * takes a free class gets the convert sequence (what-to-expect, how-was-it, a
 * couple of nudges, a last-day note if an offer is set), and a day-7 retention
 * task appears for the studio to reach out by hand. All member mail is
 * transactional and honours the member's own notification settings.
 */
export default function ConvertKeepPanel({
  enabled, keepEnabled, planId, days, exclusive, tasksTo, plans,
}: {
  enabled: boolean; keepEnabled: boolean; planId: string | null; days: number;
  exclusive: boolean; tasksTo: string;
  plans: { id: string; name: string }[];
}) {
  const [state, action] = useFormState<PlainState, FormData>(saveConvertKeep, null);
  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="convert_sequence_enabled" defaultChecked={enabled} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Run the convert sequence</span> — a new member who takes a
            free class hears from you at the right moments, and a task reminds you to reach out by hand.
            <span className="block text-[12px] leading-[18px] text-ink-3">
              Every message is about their own class or plan, from your own address, and a member can
              switch the sequence off in their settings without losing booking mail. A purchase stops it.
            </span>
          </span>
        </label>

        <div className="mt-3 border-t border-line pt-3">
          <label className="block text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Intro offer</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              The plan the sequence promotes. &ldquo;None&rdquo; sends members to your plans page instead.
            </span>
            <select name="intro_offer_plan_id" defaultValue={planId ?? ""}
                    className="mt-1.5 w-full max-w-sm rounded border border-line-2 bg-paper px-2 py-1 text-[13px] text-ink">
              <option value="">None — show the plans page</option>
              {plans.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select>
          </label>
        </div>

        <div className="mt-3 border-t border-line pt-3">
          <label className="block text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Intro window</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              How long after the free class the offer stays open (1–90 days).
            </span>
            <span className="mt-1.5 flex items-center gap-1.5">
              <input type="number" name="intro_offer_days" min={1} max={90} step={1}
                     defaultValue={days} className="w-24 rounded border border-line-2 bg-paper px-2 py-1 text-[13px] text-ink num" />
              <span className="text-[12px] text-ink-3">days</span>
            </span>
          </label>
        </div>

        <label className="mt-3 flex items-start gap-2.5 border-t border-line pt-3">
          <input type="checkbox" name="intro_offer_exclusive" defaultChecked={exclusive} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Offer only during the intro window</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              Hide the intro plan from everyone except a member inside their window, so it is a genuine
              first-timer price. (Needs an intro offer chosen above.)
            </span>
          </span>
        </label>

        <label className="mt-3 flex items-start gap-2.5 border-t border-line pt-3">
          <input type="checkbox" name="keep_sequence_enabled" defaultChecked={keepEnabled} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Run the keep sequence</span> — remind members before a plan
            ends, when pack classes are about to expire, and win lapsed members back.
            <span className="block text-[12px] leading-[18px] text-ink-3">
              Replaces the standard expiry and credit-expiry emails while on. Auto-renewing memberships
              are left alone — they renew themselves.
            </span>
          </span>
        </label>

        <div className="mt-3 border-t border-line pt-3">
          <label className="block text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Retention tasks go to</span>
            <select name="retention_tasks_to" defaultValue={tasksTo}
                    className="mt-1.5 w-full max-w-sm rounded border border-line-2 bg-paper px-2 py-1 text-[13px] text-ink">
              <option value="owner_manager">Owners and managers</option>
              <option value="front_desk">Front desk</option>
            </select>
          </label>
        </div>

        <div className="mt-3"><Save /></div>
      </div>
    </form>
  );
}
