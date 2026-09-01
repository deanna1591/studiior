"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";
import { recordPayment, type PayState } from "./actions";

type Plan = { id: string; name: string; type: string; price_cents: number; currency: string };
type Booking = { id: string; status: string; label: string };

function Submit() {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Recording…" : "Record payment"}</button>;
}

const METHODS = [
  { v: "cash",          l: "Cash" },
  { v: "bank_transfer", l: "Bank transfer" },
  { v: "gcash",         l: "GCash" },
  { v: "card_terminal", l: "Card terminal" },
  { v: "other",         l: "Something else" },
];

export default function PaymentForm({
  memberId, plans, bookings, currency,
}: {
  memberId: string;
  plans: Plan[];
  bookings: Booking[];
  currency: string;
}) {
  const [state, action] = useFormState<PayState, FormData>(recordPayment, null);
  const [kind, setKind] = useState<"plan" | "dropin" | "other">("plan");
  const [planId, setPlanId] = useState(plans[0]?.id ?? "");
  const [amount, setAmount] = useState(
    plans[0] ? (plans[0].price_cents / 100).toFixed(2) : "",
  );
  const [method, setMethod] = useState("cash");

  // Prefilled from the plan, and editable: a studio that takes 2000 off a 2500
  // plan because somebody paid the rest last month should not have to fight the
  // form about it. What was actually taken is what gets recorded.
  const choosePlan = (id: string) => {
    setPlanId(id);
    const p = plans.find((x) => x.id === id);
    if (p) setAmount((p.price_cents / 100).toFixed(2));
  };

  return (
    <form action={action} className="max-w-md space-y-4">
      {state && !state.ok && <Notice kind="error">{state.message}</Notice>}
      <input type="hidden" name="member_id" value={memberId} />

      <Field label="What is this for">
        <select name="kind" value={kind} className={inputClass}
                onChange={(e) => setKind(e.target.value as typeof kind)}>
          <option value="plan">A membership or pack</option>
          <option value="dropin">A single class</option>
          <option value="other">Something else</option>
        </select>
      </Field>

      {kind === "plan" && (
        <Field label="Which plan">
          <select name="plan_id" value={planId} className={inputClass}
                  onChange={(e) => choosePlan(e.target.value)}>
            {plans.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name} — {p.currency} {(p.price_cents / 100).toFixed(2)}
              </option>
            ))}
          </select>
        </Field>
      )}

      {kind === "dropin" && (
        <Field label="Which class">
          {bookings.length === 0 ? (
            <p className="text-[13px] leading-5 text-ink-3">
              They are not booked into anything. Book the class first, then record
              the payment against it.
            </p>
          ) : (
            <select name="booking_id" className={inputClass}>
              {bookings.map((b) => (
                <option key={b.id} value={b.id}>
                  {b.label}{b.status === "pending_payment" ? " — awaiting payment" : ""}
                </option>
              ))}
            </select>
          )}
        </Field>
      )}

      <Field label={`Amount (${currency})`}>
        <input name="amount" inputMode="decimal" required value={amount}
               onChange={(e) => setAmount(e.target.value)}
               className={`${inputClass} font-mono`} placeholder="0.00" />
      </Field>

      <Field label="How they paid">
        <select name="method" value={method} className={inputClass}
                onChange={(e) => setMethod(e.target.value)}>
          {METHODS.map((m) => <option key={m.v} value={m.v}>{m.l}</option>)}
        </select>
      </Field>

      {method === "other" && (
        <Field label="Say how">
          <input name="method_note" className={inputClass} placeholder="Cheque, voucher, staff perk…" />
        </Field>
      )}

      <Field label="Reference (optional)">
        <input name="reference" className={inputClass} placeholder="Receipt or transfer number" />
        <p className="mt-1 text-[12px] leading-4 text-ink-3">
          Whatever you will look for when you reconcile this. We do not check it.
        </p>
      </Field>

      <Field label="When (optional)">
        <input name="paid_at" type="date" className={inputClass} />
        <p className="mt-1 text-[12px] leading-4 text-ink-3">
          Leave blank for now. Set it if you are catching up on yesterday.
        </p>
      </Field>

      <Submit />
    </form>
  );
}
