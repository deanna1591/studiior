"use client";

import { useEffect, useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { buyProduct, type BuyState } from "./actions";

function BuyButton() {
  const { pending } = useFormStatus();
  return (
    <button
      disabled={pending}
      style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
      className="m-tap m-press shrink-0 rounded-full px-4 text-[13px] font-bold disabled:opacity-60"
    >
      {pending ? "Opening…" : "Buy"}
    </button>
  );
}

/** Decision 63b: buy a product online. Quantity stepper (bounded by stock when
 *  tracked); on success we get the Xendit hosted-checkout URL and navigate. */
export default function BuyProduct({ productId, max }: { productId: string; max: number | null }) {
  const [state, action] = useFormState<BuyState, FormData>(buyProduct, null);
  const [qty, setQty] = useState(1);
  const cap = max ?? 99;
  useEffect(() => {
    if (state?.ok && state.url) window.location.assign(state.url);
  }, [state]);
  return (
    <form action={action} className="mt-2 flex items-center gap-2">
      <input type="hidden" name="product_id" value={productId} />
      <input type="hidden" name="quantity" value={qty} />
      <div className="flex items-center rounded-full border border-line">
        <button type="button" onClick={() => setQty((q) => Math.max(1, q - 1))}
          className="m-press h-8 w-8 text-[16px] text-ink-2 disabled:opacity-40" disabled={qty <= 1}
          aria-label="One fewer">−</button>
        <span className="num w-6 text-center text-[14px] text-ink">{qty}</span>
        <button type="button" onClick={() => setQty((q) => Math.min(cap, q + 1))}
          className="m-press h-8 w-8 text-[16px] text-ink-2 disabled:opacity-40" disabled={qty >= cap}
          aria-label="One more">+</button>
      </div>
      <BuyButton />
      {state && !state.ok && state.message && (
        <p className="m-sub ml-1 text-coral">{state.message}</p>
      )}
    </form>
  );
}
