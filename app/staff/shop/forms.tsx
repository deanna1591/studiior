"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";
import { recordSale, adjustStock, markCollected, setProductStatus, type ShopState } from "./actions";

function Submit({ label, busy }: { label: string; busy: string }) {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? busy : label}</button>;
}
function Msg({ state }: { state: ShopState }) {
  if (!state) return null;
  return <Notice kind={"error" in state ? "error" : "ok"}>{"error" in state ? state.error : state.ok}</Notice>;
}

type ProductLite = { id: string; name: string; price_cents: number; track_stock: boolean; stock: number };
type MemberLite = { id: string; name: string };

const METHODS = [
  { v: "cash", l: "Cash" }, { v: "gcash", l: "GCash" },
  { v: "card_terminal", l: "Card (terminal)" }, { v: "bank_transfer", l: "Bank transfer" },
  { v: "other", l: "Something else" },
];

/** Record a desk sale: product, quantity, optional member, method. */
export function RecordSaleForm({ products, members, currency }:
  { products: ProductLite[]; members: MemberLite[]; currency: string }) {
  const [state, action] = useFormState<ShopState, FormData>(recordSale, null);
  const [pid, setPid] = useState(products[0]?.id ?? "");
  const [qty, setQty] = useState("1");
  const chosen = products.find((p) => p.id === pid);
  const over = chosen?.track_stock && Number(qty) > chosen.stock;
  if (products.length === 0) return <p className="text-[13px] text-ink-3">Add a product first.</p>;
  return (
    <form action={action} className="max-w-md space-y-3">
      <Msg state={state} />
      <Field label="Product">
        <select name="product_id" value={pid} className={inputClass} onChange={(e) => setPid(e.target.value)}>
          {products.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name} — {currency} {(p.price_cents / 100).toFixed(2)}
              {p.track_stock ? ` · ${p.stock} left` : ""}
            </option>
          ))}
        </select>
      </Field>
      <Field label="How many">
        <input name="quantity" inputMode="numeric" value={qty} onChange={(e) => setQty(e.target.value)}
               className={`${inputClass} font-mono w-28`} />
        {over && <p className="mt-1 rounded border-l-2 border-coral bg-coral-tint px-2 py-1.5 text-[12px] text-ink">
          Only <span className="num">{chosen!.stock}</span> left.</p>}
      </Field>
      <Field label="Member (optional)">
        <select name="member_id" className={inputClass} defaultValue="">
          <option value="">Walk-in / not a member</option>
          {members.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
        </select>
      </Field>
      <Field label="How they paid">
        <select name="method" className={inputClass} defaultValue="cash">
          {METHODS.map((m) => <option key={m.v} value={m.v}>{m.l}</option>)}
        </select>
      </Field>
      <Submit label="Record sale" busy="Recording…" />
    </form>
  );
}

/** Adjust stock with a reason (manager-up). */
export function StockForm({ productId }: { productId: string }) {
  const [state, action] = useFormState<ShopState, FormData>(adjustStock, null);
  return (
    <form action={action} className="max-w-md space-y-3">
      <Msg state={state} />
      <input type="hidden" name="product_id" value={productId} />
      <Field label="Change (use a minus to remove)">
        <input name="delta" inputMode="numeric" placeholder="e.g. 12 or -1" className={`${inputClass} font-mono w-32`} />
      </Field>
      <Field label="Why">
        <select name="reason" className={inputClass} defaultValue="restock">
          <option value="restock">Restock — new delivery</option>
          <option value="adjust">Adjust — count correction</option>
        </select>
      </Field>
      <Field label="Note (optional)">
        <input name="note" className={inputClass} placeholder="PO number, who counted…" />
      </Field>
      <Submit label="Update stock" busy="Saving…" />
    </form>
  );
}

export function CollectButton({ orderId }: { orderId: string }) {
  const [state, action] = useFormState<ShopState, FormData>(markCollected, null);
  return (
    <form action={action} className="inline">
      <input type="hidden" name="order_id" value={orderId} />
      {state && "error" in state
        ? <span className="text-[12px] text-coral">{state.error}</span>
        : <CollectBtn />}
    </form>
  );
}
function CollectBtn() {
  const { pending } = useFormStatus();
  return <button disabled={pending}
    className="rounded bg-ink px-2.5 py-1.5 text-[12px] font-medium text-paper hover:bg-ink-2 disabled:opacity-50">
    {pending ? "…" : "Collected"}</button>;
}

export function ArchiveButton({ id, archived }: { id: string; archived: boolean }) {
  const [state, action] = useFormState<ShopState, FormData>(setProductStatus, null);
  return (
    <form action={action} className="inline">
      <input type="hidden" name="id" value={id} />
      <input type="hidden" name="status" value={archived ? "active" : "archived"} />
      {state && "error" in state
        ? <span className="text-[12px] text-coral">{state.error}</span>
        : <ArchiveBtn archived={archived} />}
    </form>
  );
}
function ArchiveBtn({ archived }: { archived: boolean }) {
  const { pending } = useFormStatus();
  return <button disabled={pending}
    className="rounded border border-line-2 px-2.5 py-1.5 text-[12px] font-medium text-ink hover:bg-paper disabled:opacity-50">
    {pending ? "…" : archived ? "Back on sale" : "Archive"}</button>;
}
