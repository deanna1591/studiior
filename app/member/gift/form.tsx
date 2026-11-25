"use client";

import { useState, useTransition } from "react";
import { accentSolid } from "@/lib/accent-pair";
import { buyGift, type GiftState } from "./actions";
import { giftAmountProblem } from "@/lib/gift-card";

/**
 * Decision 110: the gift purchase form. Pick a preset or a custom amount, the
 * recipient and the buyer, an optional message and delivery date; buyGift opens
 * the Xendit session and we navigate there. Phone-first.
 */
export default function GiftForm({
  presets, minCents, currencyLabels, minLabel, currency, buyerName = "", buyerEmail = "", initialCents,
}: {
  presets: number[]; minCents: number; currencyLabels: string[]; minLabel: string; currency: string;
  buyerName?: string; buyerEmail?: string; initialCents?: number;
}) {
  // Decision 119: a prefilled amount selects its preset, or fills "Another amount".
  const startPreset = initialCents != null && presets.includes(initialCents);
  const startCustom = initialCents != null && !startPreset;
  const [amount, setAmount] = useState<number>(startPreset ? (initialCents as number) : (presets[0] ?? minCents));
  const [custom, setCustom] = useState(startCustom ? String((initialCents as number) / 100) : "");
  const [customOn, setCustomOn] = useState(startCustom);
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);

  const effectiveCents = customOn ? Math.round((Number(custom) || 0) * 100) : amount;
  // Decision 110(a): a custom amount is whole hundreds from the minimum, and the
  // card is issued at exactly that amount.
  const amountProblem = customOn && custom ? giftAmountProblem(effectiveCents, minCents) : null;

  function submit(fd: FormData) {
    setErr(null);
    fd.set("amount_cents", String(effectiveCents));
    start(async () => {
      const r: GiftState = await buyGift(null, fd);
      if (r?.ok && r.url) { window.location.assign(r.url); return; }
      setErr(r?.message ?? "That didn't work. Please try again.");
    });
  }

  return (
    <form action={submit} className="space-y-5">
      {/* Amount */}
      <fieldset>
        <legend className="m-label mb-2 text-ink">Amount</legend>
        <div className="flex flex-wrap gap-2">
          {presets.map((c, i) => (
            <button key={c} type="button"
              onClick={() => { setCustomOn(false); setAmount(c); }}
              className="m-press rounded-full px-4 py-2 text-[14px] font-semibold"
              style={!customOn && amount === c
                ? accentSolid()
                : { background: "var(--surface)", color: "var(--ink)", boxShadow: "0 1px 3px rgb(26 21 18 / 0.06)" }}>
              {currencyLabels[i]}
            </button>
          ))}
          <button type="button" onClick={() => setCustomOn(true)}
            className="m-press rounded-full px-4 py-2 text-[14px] font-semibold"
            style={customOn
              ? accentSolid()
              : { background: "var(--surface)", color: "var(--ink)", boxShadow: "0 1px 3px rgb(26 21 18 / 0.06)" }}>
            Another amount
          </button>
        </div>
        {customOn && (
          <div className="mt-2">
            <input type="number" inputMode="numeric" min={minCents / 100} step="100" value={custom}
              onChange={(e) => setCustom(e.target.value)} placeholder={`At least ${minLabel}`}
              className="w-full rounded-xl border border-line bg-surface px-3.5 py-2.5 text-[15px] text-ink" />
            <p className="m-micro mt-1 text-ink-3">At least {minLabel}, in whole hundreds.</p>
            {amountProblem && <p className="m-micro mt-1 text-ink">{amountProblem}</p>}
          </div>
        )}
      </fieldset>

      <Field name="recipient_name" label="Who is it for?" placeholder="Their name" required />
      <Field name="recipient_email" label="Their email" type="email" placeholder="them@example.com" required />
      <div>
        <label className="m-label mb-1 block text-ink">A message (optional)</label>
        <textarea name="message" rows={2} maxLength={200}
          className="w-full rounded-xl border border-line bg-surface px-3.5 py-2.5 text-[15px] text-ink"
          placeholder="Enjoy a class on me" />
      </div>
      <div>
        <label className="m-label mb-1 block text-ink">Send on (optional)</label>
        <input name="delivery_date" type="date"
          className="w-full rounded-xl border border-line bg-surface px-3.5 py-2.5 text-[15px] text-ink" />
        <p className="m-micro mt-1 text-ink-3">Leave blank to send it now.</p>
      </div>

      <div className="border-t border-line pt-4">
        <Field name="buyer_name" label="Your name" placeholder="Your name" required defaultValue={buyerName} />
        <div className="mt-4">
          <Field name="buyer_email" label="Your email (for the receipt)" type="email" placeholder="you@example.com" required defaultValue={buyerEmail} />
        </div>
      </div>

      {err && (
        <p className="rounded-lg px-3 py-2 text-[13px] leading-[19px]"
           style={{ background: "var(--coral-tint)", color: "var(--ink)" }}>{err}</p>
      )}

      <button type="submit" disabled={pending || effectiveCents < minCents || !!amountProblem}
        className="m-press w-full rounded-full py-3.5 text-center text-[16px] font-semibold disabled:opacity-60"
        style={accentSolid()}>
        {pending ? "Opening checkout…" : "Continue to payment"}
      </button>
      <p className="m-micro text-center text-ink-3">Card or GCash, on the next screen.</p>
    </form>
  );
}

function Field({
  name, label, placeholder, type = "text", required = false, defaultValue,
}: { name: string; label: string; placeholder?: string; type?: string; required?: boolean; defaultValue?: string }) {
  return (
    <div>
      <label className="m-label mb-1 block text-ink">{label}</label>
      <input name={name} type={type} placeholder={placeholder} required={required} defaultValue={defaultValue}
        className="w-full rounded-xl border border-line bg-surface px-3.5 py-2.5 text-[15px] text-ink" />
    </div>
  );
}
