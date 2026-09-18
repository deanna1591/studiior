"use client";

import { useFormState, useFormStatus } from "react-dom";
import { formatMoney } from "@/lib/plans";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveRate, copyRateToAll, type RateState } from "./rate-actions";

export type RateVersion = {
  effective_from: string;
  base_rate_cents: number;
  per_head_rate_cents: number;
  per_head_threshold: number;
  full_house_bonus_cents: number;
  private_rate_cents: number | null;
  duo_rate_cents: number | null;
  trio_rate_cents: number | null;
  pay_tier: string | null;
};

const field = "rounded border border-line-2 bg-surface px-3 py-2 text-[14px] text-ink outline-none";

function Save({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : label}</button>;
}

function fmtDate(iso: string) {
  return new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" })
    .format(new Date(`${iso}T00:00:00Z`));
}

export default function RatePanel(
  { instructorId, currency, current, history, activeCount, tomorrow, today }:
  { instructorId: string; currency: string; current: RateVersion | null;
    history: RateVersion[]; activeCount: number; tomorrow: string; today: string },
) {
  const [state, action] = useFormState<RateState, FormData>(saveRate, null);
  const [copyState, copyAction] = useFormState<RateState, FormData>(copyRateToAll, null);
  const m = (c: number | null) => (c === null ? "—" : formatMoney(c, currency));

  return (
    <div className="max-w-xl">
      {/* Current rate, or the honest absence of one. */}
      {current ? (
        <div className="rounded border border-line bg-surface p-4 text-[13px] text-ink-2">
          <p className="text-[13px] font-medium text-ink">
            {current.effective_from <= today ? "Current rate" : "Rate — takes effect " + fmtDate(current.effective_from)}
            {current.pay_tier ? ` · ${current.pay_tier}` : ""}
            {current.effective_from <= today ? ` · from ${fmtDate(current.effective_from)}` : ""}
          </p>
          <div className="mt-2 grid grid-cols-2 gap-x-6 gap-y-1">
            <span>Base <span className="font-medium text-ink">{m(current.base_rate_cents)}</span></span>
            <span>Per head above {current.per_head_threshold} <span className="font-medium text-ink">{m(current.per_head_rate_cents)}</span></span>
            <span>Full house <span className="font-medium text-ink">{m(current.full_house_bonus_cents)}</span></span>
            <span>Private / duo / trio <span className="font-medium text-ink">{m(current.private_rate_cents)} / {m(current.duo_rate_cents)} / {m(current.trio_rate_cents)}</span></span>
          </div>
        </div>
      ) : (
        <div className="rounded border border-coral-tint bg-surface p-4 text-[13px]" style={{ borderColor: "var(--coral)" }}>
          <span className="font-medium text-ink">No rate on file</span>
          <span className="text-ink-2"> — this instructor will not be paid until a rate is set below.</span>
        </div>
      )}

      {/* Copy this rate to all active instructors — one contract, entered once. */}
      {current && activeCount > 1 && (
        <form action={copyAction} className="mt-3"
              onSubmit={(e) => { if (!window.confirm(
                `Give this rate (from ${fmtDate(current.effective_from)}) to the other ${activeCount - 1} active instructor${activeCount - 1 === 1 ? "" : "s"}? Anyone who already has a rate from that date is left alone.`)) e.preventDefault(); }}>
          <input type="hidden" name="instructor_id" value={instructorId} />
          <Save label={`Copy this rate to all ${activeCount} active instructors`} />
          {copyState && <Notice kind={copyState.ok ? "ok" : "error"}>{copyState.message}</Notice>}
        </form>
      )}

      {history.length > 0 && (
        <div className="mt-4">
          <p className="text-[12px] font-medium uppercase tracking-wide text-ink-3">Rate history</p>
          <ul className="mt-1 text-[13px] text-ink-2">
            {history.map((h) => (
              <li key={h.effective_from} className="border-t border-line py-1.5">
                From {fmtDate(h.effective_from)}: base {m(h.base_rate_cents)}, per head {m(h.per_head_rate_cents)} above {h.per_head_threshold}, full house {m(h.full_house_bonus_cents)}
                {h.pay_tier ? ` · ${h.pay_tier}` : ""}
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* A NEW version only — a rate is immutable and effective-dated, so nothing
          here edits one. Effective from tomorrow by default, never today. */}
      <form action={action} className="mt-5 rounded border border-line bg-surface p-4">
        <p className="text-[13px] font-medium text-ink">Set a new rate</p>
        <p className="mt-0.5 text-[12px] text-ink-3">
          A rate is history and is never edited. This adds a version that takes over from its
          effective date; earlier classes keep the rate they were paid at.
        </p>
        <input type="hidden" name="instructor_id" value={instructorId} />
        {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

        <label className="mt-3 block">
          <span className="mb-1 block text-[13px] font-medium text-ink">Effective from</span>
          <input name="effective_from" type="date" min={tomorrow} defaultValue={tomorrow} className={field} />
          <span className="mt-1 block text-[12px] text-ink-3">Never today — an edit made this evening must not repay this morning’s class.</span>
        </label>

        <div className="mt-3 grid grid-cols-2 gap-3">
          <label className="block">
            <span className="mb-1 block text-[13px] font-medium text-ink">Base ({currency})</span>
            <input name="base" type="number" min={0} step="1" defaultValue={current ? Math.round(current.base_rate_cents / 100) : ""} className={field} />
          </label>
          <label className="block">
            <span className="mb-1 block text-[13px] font-medium text-ink">Per head ({currency})</span>
            <input name="per_head_rate" type="number" min={0} step="1" defaultValue={current ? Math.round(current.per_head_rate_cents / 100) : ""} className={field} />
          </label>
          <label className="block">
            <span className="mb-1 block text-[13px] font-medium text-ink">Per head above (count)</span>
            <input name="per_head_threshold" type="number" min={0} step="1" defaultValue={current ? current.per_head_threshold : 0} className={field} />
          </label>
          <label className="block">
            <span className="mb-1 block text-[13px] font-medium text-ink">Full house ({currency})</span>
            <input name="full_house_bonus" type="number" min={0} step="1" defaultValue={current ? Math.round(current.full_house_bonus_cents / 100) : ""} className={field} />
          </label>
        </div>

        <p className="mt-4 text-[12px] font-medium uppercase tracking-wide text-ink-3">Private sessions (optional)</p>
        <div className="mt-1 grid grid-cols-3 gap-3">
          <label className="block">
            <span className="mb-1 block text-[12px] text-ink-2">Private ({currency})</span>
            <input name="private_rate" type="number" min={0} step="1" defaultValue={current?.private_rate_cents != null ? Math.round(current.private_rate_cents / 100) : ""} className={field} />
          </label>
          <label className="block">
            <span className="mb-1 block text-[12px] text-ink-2">Duo ({currency})</span>
            <input name="duo_rate" type="number" min={0} step="1" defaultValue={current?.duo_rate_cents != null ? Math.round(current.duo_rate_cents / 100) : ""} className={field} />
          </label>
          <label className="block">
            <span className="mb-1 block text-[12px] text-ink-2">Trio ({currency})</span>
            <input name="trio_rate" type="number" min={0} step="1" defaultValue={current?.trio_rate_cents != null ? Math.round(current.trio_rate_cents / 100) : ""} className={field} />
          </label>
        </div>

        <label className="mt-3 block">
          <span className="mb-1 block text-[13px] font-medium text-ink">Tier name (optional)</span>
          <input name="pay_tier" type="text" defaultValue={current?.pay_tier ?? ""} placeholder="standard, senior…" className={`${field} w-full`} />
        </label>

        <div className="mt-4"><Save label="Set rate" /></div>
      </form>
    </div>
  );
}
