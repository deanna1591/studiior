"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";
import { saveProduct, type ShopState } from "./actions";

export type ProductDraft = {
  id?: string; name: string; description: string | null;
  price: string; track_stock: boolean; stock: number;
  low_stock_threshold: number | null; sort_order: number;
};

function Submit({ mode }: { mode: "new" | "edit" }) {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>
    {pending ? "Saving…" : mode === "new" ? "Add product" : "Save changes"}</button>;
}

export default function ProductForm({ draft, mode, currency }:
  { draft: ProductDraft; mode: "new" | "edit"; currency: string }) {
  const [state, action] = useFormState<ShopState, FormData>(saveProduct, null);
  const [track, setTrack] = useState(draft.track_stock);
  return (
    <form action={action} className="max-w-md space-y-4">
      {state && <Notice kind={"error" in state ? "error" : "ok"}>{"error" in state ? state.error : state.ok}</Notice>}
      {draft.id && <input type="hidden" name="id" value={draft.id} />}
      <Field label="Name">
        <input name="name" required defaultValue={draft.name} className={inputClass}
               placeholder="Grip socks — S" />
        <p className="mt-1 text-[12px] text-ink-3">Sizes and colours are separate products — that is how stock is counted.</p>
      </Field>
      <Field label="Short description (optional)">
        <input name="description" defaultValue={draft.description ?? ""} className={inputClass} />
      </Field>
      <Field label={`Price (${currency})`}>
        <input name="price" inputMode="decimal" required defaultValue={draft.price}
               className={`${inputClass} font-mono`} placeholder="150.00" />
      </Field>
      <label className="flex items-center gap-2 text-[14px] text-ink">
        <input type="checkbox" name="track_stock" value="1" checked={track}
               onChange={(e) => setTrack(e.target.checked)} />
        Track stock on hand
      </label>
      {track && (
        <div className="space-y-4 border-l-2 border-line pl-3">
          <Field label="Stock on hand now">
            <input name="stock" inputMode="numeric" defaultValue={String(draft.stock)}
                   className={`${inputClass} font-mono w-28`} />
          </Field>
          <Field label="Tell me when it drops to (optional)">
            <input name="low_stock_threshold" inputMode="numeric"
                   defaultValue={draft.low_stock_threshold != null ? String(draft.low_stock_threshold) : ""}
                   className={`${inputClass} font-mono w-28`} placeholder="2" />
          </Field>
        </div>
      )}
      <Field label="Display order">
        <input name="sort_order" inputMode="numeric" defaultValue={String(draft.sort_order)}
               className={`${inputClass} font-mono w-28`} />
      </Field>
      <Submit mode={mode} />
    </form>
  );
}
