"use client";

import Link from "next/link";
import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonClass, inputClass } from "@/components/ui";
import { createBatch, createShared, type CodeState } from "./actions";

export type BatchRow = {
  id: string; kind: "batch" | "shared"; name: string; pct: number; starts_on: string; ends_on: string;
  max_uses: number | null; private_sessions: boolean; cancelled: boolean; expired: boolean;
  code: string | null; codes: number; used: number; plan_names: string[];
};

function day(d: string) {
  return new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", day: "numeric", month: "short", year: "numeric" })
    .format(new Date(`${d}T00:00:00Z`));
}
function Submit({ children }: { children: React.ReactNode }) {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "…" : children}</button>;
}

function Common({ plans, products = [], privateEnabled, today }: { plans: { id: string; name: string }[]; products?: { id: string; name: string }[]; privateEnabled: boolean; today: string }) {
  return (
    <>
      <div className="flex flex-wrap items-end gap-2">
        <label className="text-[12px] text-ink-2">
          <span className="mb-1 block">Percent off</span>
          <input name="pct" type="number" min={1} max={100} required defaultValue={10} className={`${inputClass} w-24`} />
        </label>
        <label className="text-[12px] text-ink-2">
          <span className="mb-1 block">Valid from</span>
          <input name="starts_on" type="date" required defaultValue={today} className={`${inputClass} w-40`} />
        </label>
        <label className="text-[12px] text-ink-2">
          <span className="mb-1 block">Valid to</span>
          <input name="ends_on" type="date" required defaultValue={today} className={`${inputClass} w-40`} />
        </label>
      </div>
      <p className="mt-3 text-[12px] text-ink-2">Which plans (00:00 to 23:59, studio time)</p>
      <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1.5">
        {plans.map((p) => (
          <label key={p.id} className="flex items-center gap-1.5 text-[13px] text-ink">
            <input type="checkbox" name="plan_ids" value={p.id} /> {p.name}
          </label>
        ))}
        {privateEnabled && (
          <label className="flex items-center gap-1.5 text-[13px] text-ink">
            <input type="checkbox" name="private_sessions" /> Private sessions
          </label>
        )}
      </div>
      {products.length > 0 && (
        <>
          <p className="mt-3 text-[12px] text-ink-2">Which shop items</p>
          <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1.5">
            {products.map((p) => (
              <label key={p.id} className="flex items-center gap-1.5 text-[13px] text-ink">
                <input type="checkbox" name="product_ids" value={p.id} /> {p.name}
              </label>
            ))}
          </div>
        </>
      )}
    </>
  );
}

export default function CodesClient({ rows, plans, products = [], privateEnabled, today }: {
  rows: BatchRow[]; plans: { id: string; name: string }[]; products?: { id: string; name: string }[]; privateEnabled: boolean; today: string;
}) {
  const [tab, setTab] = useState<"batch" | "shared">("batch");
  const [bState, bAction] = useFormState<CodeState, FormData>(createBatch, null);
  const [sState, sAction] = useFormState<CodeState, FormData>(createShared, null);
  const state = tab === "batch" ? bState : sState;

  return (
    <div className="max-w-3xl space-y-6">
      <section className="rounded border border-line bg-surface px-3.5 py-3">
        <div className="mb-3 flex gap-1">
          {(["batch", "shared"] as const).map((k) => (
            <button key={k} type="button" onClick={() => setTab(k)}
                    className={`rounded px-3 py-1.5 text-[13px] font-semibold ${tab === k ? "bg-ink text-surface" : "text-ink-2"}`}>
              {k === "batch" ? "Unique codes" : "Shared code"}
            </button>
          ))}
        </div>
        {state && <div className="mb-2"><Notice kind={state.ok ? "ok" : "error"}>
          {state.message}{state.ok && state.batchId && <> <Link className="underline" href={`/settings/promotions/codes/${state.batchId}`}>See the codes</Link></>}
        </Notice></div>}
        {tab === "batch" ? (
          <form action={bAction} className="space-y-3">
            <p className="text-[13px] text-ink-2">Each code works once, for one purchase, by anyone who has it.</p>
            <div className="flex flex-wrap items-end gap-2">
              <label className="text-[12px] text-ink-2">
                <span className="mb-1 block">Name</span>
                <input name="name" required maxLength={60} placeholder="Influencer codes" className={`${inputClass} w-56`} />
              </label>
              <label className="text-[12px] text-ink-2">
                <span className="mb-1 block">How many codes</span>
                <input name="count" type="number" min={1} max={500} required defaultValue={20} className={`${inputClass} w-28`} />
              </label>
            </div>
            <Common plans={plans} products={products} privateEnabled={privateEnabled} today={today} />
            <Submit>Create codes</Submit>
          </form>
        ) : (
          <form action={sAction} className="space-y-3">
            <p className="text-[13px] text-ink-2">One code anyone can use, once per person, up to the number of uses you set.</p>
            <div className="flex flex-wrap items-end gap-2">
              <label className="text-[12px] text-ink-2">
                <span className="mb-1 block">Code</span>
                <input name="code" required maxLength={20} placeholder="XMAS10" className={`${inputClass} w-40 font-mono uppercase`} />
              </label>
              <label className="text-[12px] text-ink-2">
                <span className="mb-1 block">Name (optional)</span>
                <input name="name" maxLength={60} placeholder="Christmas" className={`${inputClass} w-48`} />
              </label>
              <label className="text-[12px] text-ink-2">
                <span className="mb-1 block">Maximum uses</span>
                <input name="max_uses" type="number" min={1} required defaultValue={50} className={`${inputClass} w-28`} />
              </label>
            </div>
            <Common plans={plans} products={products} privateEnabled={privateEnabled} today={today} />
            <Submit>Create code</Submit>
          </form>
        )}
      </section>

      <section>
        <h2 className="mb-2 text-[13px] font-semibold text-ink">Your codes</h2>
        {rows.length === 0 ? (
          <p className="text-[13px] text-ink-2">No discount codes yet.</p>
        ) : (
          <ul className="divide-y divide-line rounded border border-line bg-surface">
            {rows.map((r) => (
              <li key={r.id}>
                <Link href={`/settings/promotions/codes/${r.id}`} className="flex items-center justify-between gap-3 px-3.5 py-3 hover:bg-paper">
                  <span className="min-w-0">
                    <span className="block text-[14px] font-semibold text-ink">
                      {r.kind === "shared" ? <span className="font-mono">{r.code}</span> : r.name}
                      <span className="ml-2 text-[12px] font-normal text-ink-2">{r.pct}% off</span>
                    </span>
                    <span className="block text-[12px] text-ink-2">
                      {r.kind === "batch" ? `${r.codes} unique codes · ${r.used} used` : `Shared · ${r.used} of ${r.max_uses} uses`}
                      {" · "}{day(r.starts_on)} to {day(r.ends_on)}
                      {r.plan_names.length > 0 && <> · {r.plan_names.join(", ")}</>}
                      {r.private_sessions && <> · private sessions</>}
                    </span>
                  </span>
                  <span className="shrink-0 text-[12px] text-ink-2">{r.cancelled ? "Cancelled" : r.expired ? "Expired" : "Live"}</span>
                </Link>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
