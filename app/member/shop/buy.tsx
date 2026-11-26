"use client";

import { useEffect, useState } from "react";
import { accentSolid } from "@/lib/accent-pair";
import { useFormState, useFormStatus } from "react-dom";
import { buyProduct, type BuyState } from "./actions";
import { formatMoney } from "@/lib/plans";
import { creditOnCheckout, creditLines, netTotalCents } from "@/lib/reservation-credit";
import CodeBox from "@/components/code-box";
import { previewMemberCode } from "../code-actions";
import type { CodePreview } from "@/lib/discount-code";

function BuyButton({ free = false }: { free?: boolean }) {
  const { pending } = useFormStatus();
  return (
    <button
      disabled={pending}
      style={accentSolid()}
      className="m-tap m-press shrink-0 rounded-full px-4 text-[13px] font-bold disabled:opacity-60"
    >
      {pending ? "Opening…" : free ? "Complete" : "Buy"}
    </button>
  );
}

/** Decision 63b: buy a product online. Quantity stepper (bounded by stock when
 *  tracked); on success we get the Xendit hosted-checkout URL and navigate. */
export default function BuyProduct({
  productId, max, creditCents = 0, unitPriceCents = 0, currency = "",
}: {
  productId: string; max: number | null;
  creditCents?: number; unitPriceCents?: number; currency?: string;
}) {
  const [state, action] = useFormState<BuyState, FormData>(buyProduct, null);
  const [qty, setQty] = useState(1);
  // Decision 120(b): a code on this item. Re-checked when the quantity changes.
  const [code, setCode] = useState<CodePreview | null>(null);
  const cap = max ?? 99;
  useEffect(() => {
    if (state?.ok && state.url) window.location.assign(state.url);
  }, [state]);
  // Decision 103a: show the reservation credit that will apply to this order.
  const lineCents = code?.priceCents ?? unitPriceCents * qty;
  const { applied, remaining } = creditOnCheckout(creditCents, lineCents);
  const credit = creditLines(applied, remaining, (c: number) => formatMoney(c, currency));
  return (
    <>
    <form action={action} className="mt-2 flex items-center gap-2">
      <input type="hidden" name="product_id" value={productId} />
      <input type="hidden" name="quantity" value={qty} />
      {code?.code && <input type="hidden" name="code" value={code.code} />}
      <div className="flex items-center rounded-full border border-line">
        <button type="button" onClick={() => { setQty((q) => Math.max(1, q - 1)); setCode(null); }}
          className="m-press h-8 w-8 text-[16px] text-ink-2 disabled:opacity-40" disabled={qty <= 1}
          aria-label="One fewer">−</button>
        <span className="num w-6 text-center text-[14px] text-ink">{qty}</span>
        <button type="button" onClick={() => { setQty((q) => Math.min(cap, q + 1)); setCode(null); }}
          className="m-press h-8 w-8 text-[16px] text-ink-2 disabled:opacity-40" disabled={qty >= cap}
          aria-label="One more">+</button>
      </div>
      <BuyButton free={code?.priceCents === 0} />
      {state && !state.ok && state.message && (
        <p className="m-sub ml-1 text-coral">{state.message}</p>
      )}
    </form>
    <div className="mt-2">
      <CodeBox key={qty} name={null} currency={currency} onChange={setCode} compact
               preview={(c) => previewMemberCode({ code: c, productId, quantity: qty })} />
      {code?.priceCents === 0 && <p className="mt-1 text-[13px] font-semibold text-ink">Total {formatMoney(0, currency)}</p>}
    </div>
    {credit.length > 0 && (
      <div className="mt-1 text-[13px] text-lime-text">
        {credit.map((l, i) => <p key={i}>{l}</p>)}
        {applied > 0 && (
          <p className="font-semibold text-ink">
            You pay {formatMoney(netTotalCents(creditCents, lineCents), currency)}
          </p>
        )}
      </div>
    )}
    </>
  );
}
