"use client";

import { useEffect, useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonClass, buttonQuietClass, inputClass } from "@/components/ui";
import { formatMoney } from "@/lib/plans";
import { salePriceCents } from "@/lib/promo";
import { savePromotion, endPromotion, archivePromotion, type PromoState } from "./actions";

export type PromoRow = {
  id: string; name: string; pct: number; starts_on: string; ends_on: string;
  ended_at: string | null; status: "scheduled" | "running" | "ended" | "archived";
  plan_ids: string[]; plan_names: string[]; sold: number; discount_cents: number;
};
export type PromoPlan = { id: string; name: string; type: string; price_cents: number; currency: string };

const STATUS: Record<string, string> = { scheduled: "Scheduled", running: "Running", ended: "Ended", archived: "Archived" };

// A date (yyyy-mm-dd) has no time zone: read and write it in UTC so it round-trips.
function day(d: string) {
  return new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", weekday: "short", day: "numeric", month: "short" })
    .format(new Date(`${d}T00:00:00Z`));
}

function Submit({ children, quiet = false }: { children: React.ReactNode; quiet?: boolean }) {
  const { pending } = useFormStatus();
  return <button className={quiet ? buttonQuietClass : buttonClass} disabled={pending}>{pending ? "…" : children}</button>;
}

function PromoForm({ plans, currency, today, edit, onDone }: {
  plans: PromoPlan[]; currency: string; today: string; edit?: PromoRow | null; onDone?: () => void;
}) {
  const [state, action] = useFormState<PromoState, FormData>(savePromotion, null);
  const [pct, setPct] = useState<number>(edit?.pct ?? 10);
  const [ticked, setTicked] = useState<Set<string>>(new Set(edit?.plan_ids ?? []));
  const eligible = plans.filter((p) => p.type !== "recurring");
  const toggle = (id: string) => setTicked((s) => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; });
  useEffect(() => { if (state?.ok && onDone) onDone(); }, [state, onDone]);

  return (
    <form action={action} className="rounded border border-line bg-surface px-3.5 py-3">
      {edit && <input type="hidden" name="id" value={edit.id} />}
      {state && <div className="mb-2"><Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice></div>}
      <div className="flex flex-wrap items-end gap-2">
        <label className="text-[12px] text-ink-2">
          <span className="mb-1 block">Name</span>
          <input name="name" required maxLength={60} defaultValue={edit?.name ?? ""} placeholder="Holiday Sale"
                 className={`${inputClass} w-56`} />
        </label>
        <label className="text-[12px] text-ink-2">
          <span className="mb-1 block">Percent off</span>
          <input name="pct" type="number" min={1} max={90} step={1} required value={pct}
                 onChange={(e) => setPct(Number(e.target.value))} className={`${inputClass} w-24`} />
        </label>
        <label className="text-[12px] text-ink-2">
          <span className="mb-1 block">From</span>
          <input name="starts_on" type="date" required min={today} defaultValue={edit?.starts_on ?? today}
                 className={`${inputClass} w-40`} />
        </label>
        <label className="text-[12px] text-ink-2">
          <span className="mb-1 block">To (last day)</span>
          <input name="ends_on" type="date" required min={today} defaultValue={edit?.ends_on ?? ""}
                 className={`${inputClass} w-40`} />
        </label>
      </div>
      <p className="mt-3 text-[12px] font-medium text-ink-2">Plans on sale</p>
      <ul className="mt-1 space-y-1">
        {eligible.map((p) => {
          const on = ticked.has(p.id);
          const sale = pct >= 1 && pct <= 90 ? salePriceCents(p.price_cents, pct) : p.price_cents;
          return (
            <li key={p.id}>
              <label className="flex items-center gap-2 text-[13px] text-ink">
                <input type="checkbox" name="plan_ids" value={p.id} checked={on} onChange={() => toggle(p.id)} />
                <span>{p.name}</span>
                <span className="num text-[12px] text-ink-2">
                  {on
                    ? <><s>{formatMoney(p.price_cents, p.currency || currency)}</s> {formatMoney(sale, p.currency || currency)}</>
                    : formatMoney(p.price_cents, p.currency || currency)}
                </span>
              </label>
            </li>
          );
        })}
      </ul>
      <p className="mt-2 text-[12px] leading-[18px] text-ink-2">
        The sale runs from 00:00 on the first day to the end of the last day, studio time. Recurring
        memberships are not listed: they cannot carry a promotion.
      </p>
      <div className="mt-3 flex items-center gap-2">
        <Submit>{edit ? "Save changes" : "Create promotion"}</Submit>
        {edit && onDone && (
          <button type="button" onClick={onDone} className="text-[12px] text-ink-2 underline underline-offset-4">Cancel</button>
        )}
      </div>
    </form>
  );
}

function RowActions({ row }: { row: PromoRow }) {
  const [endState, end] = useFormState<PromoState, FormData>(endPromotion, null);
  const [arcState, arc] = useFormState<PromoState, FormData>(archivePromotion, null);
  const msg = endState ?? arcState;
  return (
    <div className="flex flex-wrap items-center gap-2">
      {row.status === "running" && (
        <form action={end} onSubmit={(e) => {
          if (!window.confirm(`End ${row.name} now? New checkouts pay the list price; anyone already at checkout keeps the sale price.`)) e.preventDefault();
        }}>
          <input type="hidden" name="id" value={row.id} />
          <Submit quiet>End now</Submit>
        </form>
      )}
      {(row.status === "ended" || row.status === "scheduled") && (
        <form action={arc}>
          <input type="hidden" name="id" value={row.id} />
          <Submit quiet>Archive</Submit>
        </form>
      )}
      {msg && !msg.ok && <span className="text-[12px] text-ink">{msg.message}</span>}
    </div>
  );
}

export default function PromotionsClient({ rows, plans, currency, today }: {
  rows: PromoRow[]; plans: PromoPlan[]; currency: string; today: string;
}) {
  const [editing, setEditing] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);

  return (
    <div className="max-w-3xl space-y-4">
      {creating ? (
        <PromoForm plans={plans} currency={currency} today={today} onDone={() => setCreating(false)} />
      ) : (
        <button onClick={() => setCreating(true)} className={buttonClass}>New promotion</button>
      )}

      {rows.length === 0 ? (
        <p className="text-[13px] text-ink-2">No promotions yet.</p>
      ) : (
        <ul className="space-y-2">
          {rows.map((r) => editing === r.id ? (
            <li key={r.id}><PromoForm plans={plans} currency={currency} today={today} edit={r} onDone={() => setEditing(null)} /></li>
          ) : (
            <li key={r.id} className="rounded border border-line bg-surface px-3.5 py-3">
              <div className="flex flex-wrap items-baseline justify-between gap-2">
                <span className="text-[14px] font-medium text-ink">
                  {r.name} <span className="num text-ink-2">· {r.pct}% off</span>
                </span>
                <span className="rounded-full px-2 py-0.5 text-[11.5px] font-medium text-ink"
                      style={{ background: r.status === "running" ? "var(--lime-tint)" : "var(--paper)" }}>
                  {STATUS[r.status]}
                </span>
              </div>
              <p className="mt-1 text-[12.5px] text-ink-2">
                {day(r.starts_on)} to {day(r.ends_on)}
                {r.ended_at && <> · ended early</>}
                {" · "}{r.plan_names.join(", ")}
              </p>
              <p className="mt-1 text-[12.5px] text-ink-2">
                <span className="num">{r.sold}</span> sold
                {r.discount_cents > 0 && <> · <span className="num">{formatMoney(r.discount_cents, currency)}</span> discount given</>}
              </p>
              <div className="mt-2 flex items-center gap-3">
                {r.status === "scheduled" && (
                  <button onClick={() => setEditing(r.id)} className={buttonQuietClass}>Edit</button>
                )}
                <RowActions row={r} />
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
