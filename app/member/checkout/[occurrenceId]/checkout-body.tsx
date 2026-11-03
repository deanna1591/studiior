"use client";

import { useEffect, useState, useTransition } from "react";
import { useFormState, useFormStatus } from "react-dom";
import Link from "next/link";
import { formatMoney } from "@/lib/plans";
import { haptic } from "@/lib/haptics";
import GuestInvite from "@/components/member/guest-invite";
import { checkoutPay, payAtDesk, type DeskState } from "./actions";
import type { BuyState } from "@/app/member/account/plan/actions";

export type CheckoutPlanRow = {
  id: string; type: string; name: string;
  price_cents: number; currency: string; help: string;
};

/**
 * Decision 88 slice A — the checkout picker. SSR gives it the already-ordered,
 * already-filtered plans and the facts; this owns only the client state the
 * spec asks for: which plan is selected (the summary total follows), and the
 * pay sheet. No full navigation on a radio change — the money call happens only
 * from the sheet's Pay button. The hold + payment are the existing path
 * (checkoutPay → book_class hold + the shared Xendit session).
 */
export default function CheckoutBody({
  occId, className, whenLabel, instructorFirst, costLine, covered,
  plans, guestAvailable, deskPayAvailable, payeeNoticeName, studioName,
}: {
  occId: string;
  className: string;
  whenLabel: string;
  instructorFirst: string | null;
  costLine: string;
  covered: boolean;
  plans: CheckoutPlanRow[];
  guestAvailable: boolean;
  deskPayAvailable: boolean;
  payeeNoticeName: string | null;
  studioName: string;
}) {
  // Decision 67(b): when online payments settle to an account under a different
  // legal name, say so before the member leaves for Xendit. Blank = no line. A
  // trailing period on the stored name is dropped so the sentence's own period
  // does not double up ("Corp.. That's").
  const payee = payeeNoticeName?.trim().replace(/\.+$/, "");
  const payeeLine = payee
    ? `Card and GCash payments for ${studioName} are processed by ${payee}. That's the name you'll see on the payment page and on your statement.`
    : null;
  const [selectedId, setSelectedId] = useState(plans[0]?.id ?? "");
  const selected = plans.find((p) => p.id === selectedId) ?? plans[0] ?? null;
  const [sheetOpen, setSheetOpen] = useState(false);

  const [payState, pay] = useFormState<BuyState, FormData>(checkoutPay, null);
  useEffect(() => { if (payState?.ok && payState.url) window.location.assign(payState.url); }, [payState]);

  const [deskState, setDeskState] = useState<DeskState>(null);
  const [deskPending, startDesk] = useTransition();
  function onPayAtDesk() {
    haptic("tap");
    setDeskState(null);
    startDesk(async () => {
      const fd = new FormData();
      fd.set("occurrence_id", occId);
      const res = await payAtDesk(null, fd);
      if (res && "ok" in res) window.location.assign(`/class/${occId}`);
      else setDeskState(res);
    });
  }

  const deskSelected = selected?.type === "drop_in";

  return (
    <>
      {/* 1. Selected class */}
      <div className="m-card p-4">
        <h2 className="text-[17px] font-semibold leading-6 text-ink">{className}</h2>
        <p className="m-sub mt-1 text-ink-2">{whenLabel}</p>
        {instructorFirst && <p className="m-sub mt-0.5 text-ink-2">with {instructorFirst}</p>}
        <p className="mt-3 inline-flex rounded-full px-2.5 py-0.5 text-[12px] font-semibold leading-5 text-ink"
           style={{ background: "var(--accent-chip)" }}>{costLine}</p>
        {covered && (
          <p className="m-sub mt-3 text-ink-2">
            Your plan already covers this class.{" "}
            <Link href={`/class/${occId}`} className="text-lime-text underline underline-offset-4">Book it from the class page</Link>.
          </p>
        )}
      </div>

      {plans.length === 0 ? (
        <div className="m-card mt-3 p-4">
          <p className="m-sub text-ink-2">There&rsquo;s nothing to buy online for this class yet — ask the studio.</p>
        </div>
      ) : (
        <>
          {/* 2. Add a guest (existing guest-pass flow), only when one is available */}
          {guestAvailable && <GuestInvite occurrenceId={occId} />}

          {/* 3. Choose how to pay */}
          <section className="mt-5">
            <h2 className="section-label text-ink-2">Choose how to pay</h2>
            <ul className="mt-3 space-y-2.5">
              {plans.map((p) => {
                const on = p.id === selectedId;
                return (
                  <li key={p.id}>
                    <label className="m-card m-press flex cursor-pointer items-center gap-3 p-4"
                           style={on ? { border: "1.5px solid var(--accent-solid)" } : { border: "1.5px solid transparent" }}>
                      <input type="radio" name="checkout_plan" value={p.id} checked={on}
                             onChange={() => { setSelectedId(p.id); haptic("tap"); }}
                             className="sr-only" />
                      <span aria-hidden className="grid h-5 w-5 shrink-0 place-items-center rounded-full border"
                            style={{ borderColor: on ? "var(--accent-solid)" : "var(--line)" }}>
                        {on && <span className="h-2.5 w-2.5 rounded-full" style={{ background: "var(--accent-solid)" }} />}
                      </span>
                      <span className="min-w-0 flex-1">
                        <span className="block text-[15px] font-semibold leading-5 text-ink">{p.name}</span>
                        {p.help && <span className="m-sub mt-0.5 block text-ink-3">{p.help}</span>}
                      </span>
                      <span className="num shrink-0 text-[15px] font-semibold text-ink">
                        {formatMoney(p.price_cents, p.currency)}
                      </span>
                    </label>
                  </li>
                );
              })}
            </ul>
          </section>

          {/* 4. Summary */}
          {selected && (
            <section className="m-card mt-5 p-4">
              <h2 className="section-label text-ink-2">Summary</h2>
              <div className="mt-2 flex items-baseline justify-between gap-3">
                <span className="m-sub text-ink-2">{selected.name}</span>
                <span className="num text-[15px] text-ink">{formatMoney(selected.price_cents, selected.currency)}</span>
              </div>
              <div className="mt-2 flex items-baseline justify-between gap-3 border-t border-line pt-2">
                <span className="text-[15px] font-semibold text-ink">Total</span>
                <span className="num text-[17px] font-semibold text-ink">{formatMoney(selected.price_cents, selected.currency)}</span>
              </div>
            </section>
          )}

          {/* 5. Buttons */}
          <div className="mt-5">
            {payeeLine && <p className="m-sub mb-3 text-ink-3">{payeeLine}</p>}
            <button
              onClick={() => { haptic("tap"); setSheetOpen(true); }}
              disabled={!selected}
              style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
              className="m-action m-press w-full rounded-xl px-4 text-[16px] font-semibold disabled:opacity-60">
              Continue to pay
            </button>

            {deskSelected && deskPayAvailable ? (
              <>
                <button onClick={onPayAtDesk} disabled={deskPending}
                        className="m-press mt-3 w-full rounded-xl px-4 py-3 text-[15px] font-semibold text-ink disabled:opacity-60"
                        style={{ background: "var(--accent-chip)" }}>
                  {deskPending ? "One moment…" : "Pay at the desk"}
                </button>
                {deskState && "error" in deskState && (
                  <p className="m-sub mt-2 text-center text-coral">{deskState.error}</p>
                )}
              </>
            ) : (
              // Decision 73c: desk pay off for this member (or a non-drop-in is
              // selected, which is never a desk payment) — tell them to pay online.
              !deskPayAvailable && (
                <p className="m-sub mt-3 text-center text-ink-3">
                  Pay online to book. Paying at the desk is not available on this account.
                </p>
              )
            )}
          </div>

          {/* Xendit sheet: amount, the methods the hosted page accepts, and the
              Pay button that holds the seat and opens the hosted checkout. No
              "Save this card" checkbox — the Xendit integration uses one-time
              hosted Payment Sessions and cannot charge a saved card (that is
              Decision 67, not built). */}
          {sheetOpen && selected && (
            <div className="fixed inset-0 z-50 flex items-end justify-center" role="dialog" aria-modal="true">
              <button aria-label="Close" onClick={() => setSheetOpen(false)}
                      className="absolute inset-0 bg-black/40" />
              <div className="relative w-full max-w-lg rounded-t-[22px] bg-surface p-5 pb-8 shadow-xl">
                <div className="mx-auto mb-4 h-1 w-10 rounded-full" style={{ background: "var(--line)" }} />
                <p className="text-center text-[13px] text-ink-2">You&rsquo;ll pay</p>
                <p className="num mt-0.5 text-center text-[30px] font-semibold leading-9 text-ink">
                  {formatMoney(selected.price_cents, selected.currency)}
                </p>
                <p className="m-sub mt-2 text-center text-ink-3">Card or GCash, on the next screen.</p>
                {payeeLine && <p className="m-sub mt-2 text-center text-ink-3">{payeeLine}</p>}

                <form action={pay} className="mt-5">
                  <input type="hidden" name="occurrence_id" value={occId} />
                  <input type="hidden" name="plan_id" value={selected.id} />
                  <PaySubmit amount={formatMoney(selected.price_cents, selected.currency)} />
                </form>
                {payState && !payState.ok && (
                  <p className="m-sub mt-3 text-center text-coral">
                    {/* A hold refusal (full, past cutoff) is specific; anything
                        else is the standard "nothing was charged" line. */}
                    {payState.message
                      ? payState.message
                      : <>Payment did not go through. Nothing was charged. Try again{deskPayAvailable ? " or pay at the desk" : ""}.</>}
                  </p>
                )}
                <button onClick={() => setSheetOpen(false)}
                        className="m-press mt-3 w-full py-2 text-center text-[14px] text-ink-2">
                  Not now
                </button>
              </div>
            </div>
          )}
        </>
      )}
    </>
  );
}

function PaySubmit({ amount }: { amount: string }) {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending} onClick={() => haptic("tap")}
            style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
            className="m-action m-press w-full rounded-xl px-4 text-[16px] font-semibold disabled:opacity-60">
      {pending ? "Opening…" : `Pay ${amount}`}
    </button>
  );
}
