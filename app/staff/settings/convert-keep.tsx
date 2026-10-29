"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useFormStatus } from "react-dom";
import { useFormState } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { templateKeysForMaster, type TemplateKey } from "@/lib/templates";
import { setTemplateEnabled } from "@/app/staff/settings/templates/actions";
import { saveConvertKeep, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Decision 78e — the per-email switches beneath a master switch. Each toggle
 * saves on its own (like the plans-reorder featured/badge controls), writing
 * studio_settings.disabled_templates through setTemplateEnabled. The master
 * switch above still has to be on for any of these to send.
 */
function TemplateToggleList({
  master, keys, disabled, customised,
}: { master: "convert" | "keep"; keys: TemplateKey[]; disabled: Set<string>; customised: Set<string> }) {
  const router = useRouter();
  const [off, setOff] = useState<Set<string>>(new Set(disabled));
  const [pending, start] = useTransition();
  const toggle = (key: string) => {
    const enable = off.has(key);
    start(async () => {
      const r = await setTemplateEnabled(key, enable);
      if (!("error" in r)) {
        setOff((prev) => {
          const n = new Set(prev);
          if (enable) n.delete(key); else n.add(key);
          return n;
        });
        router.refresh();
      }
    });
  };
  return (
    <div className="mt-3 rounded border border-line bg-surface px-3.5 py-3">
      <div className="text-[13px] font-medium text-ink">
        {master === "convert" ? "Which convert emails to send" : "Which keep emails to send"}
      </div>
      <p className="mt-0.5 text-[12px] leading-[18px] text-ink-3">
        Switch any one off and it is never sent. The master switch above still has to be on.
      </p>
      <div className="mt-2 divide-y divide-line">
        {keys.map((k) => {
          const isOff = off.has(k.key);
          return (
            <div key={k.key} className="flex items-start justify-between gap-3 py-2">
              <span className="min-w-0">
                <Link href={`/settings/templates/${k.key}`}
                  className="text-[13px] text-ink underline-offset-2 hover:underline">{k.label}</Link>
                <span className="mt-0.5 block text-[12px] leading-[17px] text-ink-3">{k.when}</span>
              </span>
              <span className="flex shrink-0 items-center gap-2 pt-0.5">
                {customised.has(k.key)
                  ? <span className="rounded bg-accent-chip px-1.5 py-0.5 text-[11px] text-ink">Customised</span>
                  : <span className="text-[12px] text-ink-3">Default</span>}
                <button type="button" onClick={() => toggle(k.key)} disabled={pending}
                  aria-pressed={!isOff}
                  className={`rounded px-2.5 py-1 text-[12px] font-medium disabled:opacity-50 ${
                    isOff ? "border border-line-2 bg-surface text-ink-2 hover:text-ink" : "bg-accent-chip text-ink"}`}>
                  {isOff ? "Off" : "On"}
                </button>
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

/**
 * Decision 78 — "Convert and keep". Off by default. When on, a new member who
 * takes a free class gets the convert sequence (what-to-expect, how-was-it, a
 * couple of nudges, a last-day note if an offer is set), and a day-7 retention
 * task appears for the studio to reach out by hand. All member mail is
 * transactional and honours the member's own notification settings.
 */
export default function ConvertKeepPanel({
  enabled, keepEnabled, tasksEnabled, planId, days, exclusive, tasksTo, plans,
  aiDrafts, studioVoice, bookFirstCap, disabledTemplates, customisedTemplates, freeFirstEnabled,
}: {
  enabled: boolean; keepEnabled: boolean; tasksEnabled: boolean;
  planId: string | null; days: number;
  exclusive: boolean; tasksTo: string;
  plans: { id: string; name: string }[];
  aiDrafts: boolean; studioVoice: string | null; bookFirstCap: number;
  disabledTemplates: string[]; customisedTemplates: string[]; freeFirstEnabled: boolean;
}) {
  const [state, action] = useFormState<PlainState, FormData>(saveConvertKeep, null);
  const off = new Set(disabledTemplates);
  const customised = new Set(customisedTemplates);
  return (
    <div className="max-w-2xl">
    <form action={action}>
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
            <span className="font-medium">Book-your-free-class emails per night</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              Members who signed up but never booked get a nudge at day 1 and day 7. This caps how
              many go out each night, oldest first.
            </span>
            <input type="number" name="convert_book_first_daily_cap" min={0} max={1000} step={1}
                   defaultValue={bookFirstCap}
                   className="mt-1.5 w-24 rounded border border-line-2 bg-paper px-2 py-1 text-[13px] text-ink num" />
          </label>
        </div>

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

        <label className="mt-3 flex items-start gap-2.5 border-t border-line pt-3">
          <input type="checkbox" name="retention_tasks_enabled" defaultChecked={tasksEnabled} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Raise retention tasks</span> — a task when a member&rsquo;s
            rhythm slips to &ldquo;at risk&rdquo;, a soft note when they start drifting, and a heads-up
            to their instructor.
            <span className="block text-[12px] leading-[18px] text-ink-3">
              Needs the daily health check the system runs for you. Tasks and drifting members appear
              on the <a href="/retention" className="text-lime-text underline underline-offset-2">Retention</a> screen.
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

        <label className="mt-3 flex items-start gap-2.5 border-t border-line pt-3">
          <input type="checkbox" name="ai_drafts_enabled" defaultChecked={aiDrafts} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">AI drafts</span> — Draft with AI in the retention composer.
            Sends the member&rsquo;s first name, class history and plan details to an AI model to write a
            draft. Off by default.
            <span className="block text-[12px] leading-[18px] text-ink-3">
              You always read and edit the draft before it sends; nothing is sent automatically.
            </span>
          </span>
        </label>

        <div className="mt-3 border-t border-line pt-3">
          <label className="block text-[13px] leading-[19px] text-ink">
            <span className="font-medium">How your studio speaks</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              A few lines on your tone, so AI drafts sound like you.
            </span>
            <textarea name="studio_voice" defaultValue={studioVoice ?? ""} rows={4}
              placeholder="Warm and encouraging, never pushy. We use first names, keep it short, and sign off from the team."
              className="mt-1.5 w-full max-w-lg rounded border border-line-2 bg-paper px-2 py-1.5 text-[13px] leading-[19px] text-ink" />
          </label>
        </div>

        <div className="mt-3"><Save /></div>
      </div>

      <a href="/settings/templates"
         className="mt-3 flex items-center justify-between rounded border border-line bg-surface px-3.5 py-3 hover:bg-paper">
        <span className="text-[13px] leading-[19px] text-ink">
          <span className="font-medium">Email templates</span>
          <span className="block text-[12px] leading-[18px] text-ink-3">
            Edit the convert, keep, retention and closure wording in your own voice.
          </span>
        </span>
        <span className="text-[13px] text-ink-2">Edit →</span>
      </a>
    </form>

    {/* The convert emails only ever fire for a free-first taker, so the list is
        hidden while free first class is off — the keys keep their switches. */}
    {freeFirstEnabled && (
      <TemplateToggleList master="convert" keys={templateKeysForMaster("convert")} disabled={off} customised={customised} />
    )}
    <TemplateToggleList master="keep" keys={templateKeysForMaster("keep")} disabled={off} customised={customised} />
    </div>
  );
}
