"use client";

import { useEffect, useState, useTransition } from "react";
import { fromStudioWall } from "@/lib/tz";
import {
  saveCampaign, sendTest, sendNow, scheduleCampaign,
  audienceCount, type AudienceFilter,
} from "./actions";

const PLAN_STATES: [string, string][] = [
  ["", "Everyone"],
  ["on_plan", "On a plan"],
  ["expiring", "Expiring"],
  ["expired", "Expired"],
  ["free_only", "Free class only"],
  ["none", "No plan"],
];
const HEALTH: [string, string][] = [
  ["", "Any"],
  ["healthy", "Healthy"],
  ["drifting", "Drifting"],
  ["at_risk", "At risk"],
  ["new", "New"],
  ["insufficient_history", "Not enough history"],
];

/**
 * Decision 50 — the draft composer. The audience count is live and consent-only
 * ("who said yes to news"); the preview shows the email frame with the footer a
 * recipient will see. Every send/test/schedule saves the current values first,
 * so the database row is what is on screen.
 */
export default function Editor({
  id, initialSubject, initialBody, initialFilter, studioName, timeZone,
}: {
  id: string;
  initialSubject: string;
  initialBody: string;
  initialFilter: AudienceFilter;
  studioName: string;
  timeZone: string;
}) {
  const [subject, setSubject] = useState(initialSubject);
  const [body, setBody] = useState(initialBody);
  const [planState, setPlanState] = useState(initialFilter.plan_state ?? "");
  const [health, setHealth] = useState(initialFilter.health ?? "");
  const [joinedDays, setJoinedDays] = useState(
    initialFilter.joined_days ? String(initialFilter.joined_days) : "");
  const [count, setCount] = useState<number | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [date, setDate] = useState("");
  const [time, setTime] = useState("");
  const [pending, startTransition] = useTransition();

  const filter = (): AudienceFilter => ({
    plan_state: planState || null,
    health: health || null,
    joined_days: joinedDays ? Number(joinedDays) : null,
  });

  // Live audience count — recomputes whenever a filter changes.
  useEffect(() => {
    let live = true;
    audienceCount(id, filter()).then((r) => {
      if (!live) return;
      setCount("count" in r ? r.count : null);
    });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [planState, health, joinedDays]);

  const run = (fn: () => Promise<{ ok: true; sentence?: string } | { error: string }>) =>
    startTransition(async () => {
      setErr(null); setMsg(null);
      const r = await fn();
      if ("error" in r) setErr(r.error);
      else setMsg(r.sentence ?? "Done.");
    });

  const paras = body.split(/\n\n+/).filter((p) => p.trim().length > 0);

  return (
    <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
      {/* Compose */}
      <div>
        <label className="block text-[12px] font-medium text-ink-2">Subject</label>
        <input
          value={subject} onChange={(e) => setSubject(e.target.value)}
          className="mt-1 w-full rounded border border-line-2 bg-surface px-3 py-2 text-[14px] text-ink"
          placeholder="What members will see first"
        />

        <label className="mt-4 block text-[12px] font-medium text-ink-2">Message</label>
        <textarea
          value={body} onChange={(e) => setBody(e.target.value)}
          rows={10}
          className="mt-1 w-full rounded border border-line-2 bg-surface px-3 py-2 text-[14px] leading-[21px] text-ink"
          placeholder={"Plain text. Leave a blank line between paragraphs."}
        />

        <fieldset className="mt-5 rounded border border-line p-3">
          <legend className="px-1 text-[12px] font-medium text-ink-2">Who it goes to</legend>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
            <label className="block">
              <span className="block text-[11px] text-ink-3">Plan</span>
              <select value={planState} onChange={(e) => setPlanState(e.target.value)}
                className="mt-1 w-full rounded border border-line-2 bg-surface px-2 py-1.5 text-[13px] text-ink">
                {PLAN_STATES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
              </select>
            </label>
            <label className="block">
              <span className="block text-[11px] text-ink-3">Health</span>
              <select value={health} onChange={(e) => setHealth(e.target.value)}
                className="mt-1 w-full rounded border border-line-2 bg-surface px-2 py-1.5 text-[13px] text-ink">
                {HEALTH.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
              </select>
            </label>
            <label className="block">
              <span className="block text-[11px] text-ink-3">Joined in last … days</span>
              <input value={joinedDays} onChange={(e) => setJoinedDays(e.target.value.replace(/\D/g, ""))}
                inputMode="numeric" placeholder="any"
                className="mt-1 w-full rounded border border-line-2 bg-surface px-2 py-1.5 text-[13px] text-ink" />
            </label>
          </div>
          <p className="mt-3 text-[13px] leading-5 text-ink">
            {count === null
              ? "Counting…"
              : <>Will go to <span className="num font-semibold">{count}</span>{" "}
                 member{count === 1 ? "" : "s"} who said yes to news.</>}
          </p>
        </fieldset>

        <div className="mt-5 flex flex-wrap items-center gap-2">
          <button type="button" disabled={pending}
            onClick={() => run(() => saveCampaign(id, subject, body, filter()))}
            className="rounded border border-line-2 bg-surface px-3 py-2 text-[13px] font-medium text-ink hover:bg-paper disabled:opacity-50">
            Save draft
          </button>
          <button type="button" disabled={pending}
            onClick={() => run(() => sendTest(id, subject, body, filter()))}
            className="rounded border border-line-2 bg-surface px-3 py-2 text-[13px] font-medium text-ink hover:bg-paper disabled:opacity-50">
            Send a test to me
          </button>
          <button type="button" disabled={pending}
            onClick={() => {
              if (confirm(`Send this to ${count ?? "the"} member${count === 1 ? "" : "s"} now?`))
                run(() => sendNow(id, subject, body, filter()));
            }}
            className="rounded bg-ink px-3 py-2 text-[13px] font-medium text-paper hover:bg-ink-2 disabled:opacity-50">
            Send now
          </button>
        </div>

        <div className="mt-3 flex flex-wrap items-end gap-2 rounded border border-line p-3">
          <label className="block">
            <span className="block text-[11px] text-ink-3">Date</span>
            <input type="date" value={date} onChange={(e) => setDate(e.target.value)}
              className="mt-1 rounded border border-line-2 bg-surface px-2 py-1.5 text-[13px] text-ink" />
          </label>
          <label className="block">
            <span className="block text-[11px] text-ink-3">Time ({timeZone})</span>
            <input type="time" value={time} onChange={(e) => setTime(e.target.value)}
              className="mt-1 rounded border border-line-2 bg-surface px-2 py-1.5 text-[13px] text-ink" />
          </label>
          <button type="button" disabled={pending || !date || !time}
            onClick={() => {
              const [y, m, d] = date.split("-").map(Number);
              const [hh, mm] = time.split(":").map(Number);
              const wall = new Date(y, m - 1, d, hh, mm, 0);
              const iso = fromStudioWall(wall, timeZone).toISOString();
              run(() => scheduleCampaign(id, subject, body, filter(), iso));
            }}
            className="rounded border border-line-2 bg-surface px-3 py-2 text-[13px] font-medium text-ink hover:bg-paper disabled:opacity-50">
            Schedule
          </button>
        </div>

        {msg && <p className="mt-3 text-[13px] text-ink">{msg}</p>}
        {err && <p className="mt-3 text-[13px] text-coral">{err}</p>}
      </div>

      {/* Preview — the email frame with the footer a recipient sees. */}
      <div>
        <span className="block text-[12px] font-medium text-ink-2">Preview</span>
        <div className="mt-1 rounded-lg border border-line bg-surface p-5">
          <div className="mb-3 text-[17px] font-semibold text-ink">{studioName}</div>
          <div className="mb-4 h-[3px] w-11 rounded bg-accent-solid" />
          <p className="text-[15px] font-semibold text-ink">{subject || "Subject"}</p>
          <div className="mt-3 space-y-3 text-[14px] leading-[21px] text-ink">
            {paras.length ? paras.map((p, i) => <p key={i}>{p}</p>)
              : <p className="text-ink-3">Your message appears here.</p>}
          </div>
          <p className="mt-6 border-t border-line pt-3 text-[12px] leading-4 text-ink-3">
            You’re receiving this because you said yes to news from {studioName}.{" "}
            <span className="underline">Unsubscribe</span>
          </p>
        </div>
      </div>
    </div>
  );
}
