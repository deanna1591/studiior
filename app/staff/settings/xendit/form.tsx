"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Field, Notice, inputClass, buttonClass } from "@/components/ui";
import {
  connectXendit, testXenditConnection, disconnectXendit, syncPendingXendit,
  type XenditState,
} from "./actions";

function Submit({ idle, busy }: { idle: string; busy: string }) {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? busy : idle}</button>;
}

export function ConnectForm() {
  const [state, action] = useFormState<XenditState, FormData>(connectXendit, null);
  return (
    <form action={action} className="space-y-4">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <Field label="Secret API key" hint="From Xendit → Settings → API Keys. Use your test-mode key while testing.">
        <input name="secret_key" type="password" autoComplete="off" className={inputClass}
               placeholder="xnd_development_… or xnd_production_…" required />
      </Field>
      <Field label="Callback verification token" hint="Xendit → Settings → Webhooks → Verification Token. We store only a hash of it.">
        <input name="callback_token" type="password" autoComplete="off" className={inputClass} required />
      </Field>
      <label className="flex items-center gap-2 text-[13px] text-ink">
        <input type="checkbox" name="test_mode" defaultChecked className="h-4 w-4" />
        Test mode (uncheck only when you paste a live key)
      </label>
      <Submit idle="Connect Xendit" busy="Verifying with Xendit…" />
    </form>
  );
}

type PendingPurchase = {
  id: string; amountCents: number; currency: string;
  lastResult: string | null; lastCheckAt: string | null;
};

type WebhookEvent = {
  eventType: string | null; result: string | null; error: string | null; receivedAt: string;
};

export function ConnectedPanel({
  keyLast4, testMode, lastVerifiedAt, callbackUrl, pending = [], events = [],
}: { keyLast4: string | null; testMode: boolean; lastVerifiedAt: string | null; callbackUrl: string; pending?: PendingPurchase[]; events?: WebhookEvent[] }) {
  const [testState, testAction] = useFormState<XenditState, FormData>(testXenditConnection, null);
  const [syncState, syncAction] = useFormState<XenditState, FormData>(syncPendingXendit, null);
  const [offState, offAction] = useFormState<XenditState, FormData>(disconnectXendit, null);
  return (
    <div className="space-y-4">
      <p className="text-[14px] leading-[22px] text-ink">
        Connected to Xendit{keyLast4 && <> · key ending <span className="font-mono text-[13px]">{keyLast4}</span></>}
        {" · "}{testMode ? "test mode" : "live mode"}.
      </p>
      {lastVerifiedAt && (
        <p className="text-[12px] text-ink-3">Last verified {new Date(lastVerifiedAt).toLocaleString()}.</p>
      )}

      <Field label="Callback URL" hint="Paste this into Xendit → Settings → Webhooks for the Payment (payment.succeeded / payment.failure) events.">
        <input readOnly value={callbackUrl} className={`${inputClass} font-mono text-[12px]`}
               onFocus={(e) => e.currentTarget.select()} />
      </Field>

      <div className="flex flex-wrap gap-2">
        <form action={testAction}><Submit idle="Test connection" busy="Checking…" /></form>
        <form action={syncAction}><Submit idle="Check pending payments" busy="Asking Xendit…" /></form>
      </div>
      {testState && <Notice kind={testState.ok ? "ok" : "error"}>{testState.message}</Notice>}
      {syncState && <Notice kind={syncState.ok ? "ok" : "error"}>{syncState.message}</Notice>}

      {pending.length > 0 && (
        <div className="border-t border-line pt-4">
          <p className="text-[13px] font-semibold text-ink">Pending payments</p>
          <p className="mb-2 text-[12px] text-ink-3">
            Waiting to confirm. The last column is what the member app’s own check saw —
            it tells you why a payment is still pending.
          </p>
          <ul className="space-y-1">
            {pending.map((p) => (
              <li key={p.id} className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-0.5 text-[12px]">
                <span className="font-mono text-ink-2">{p.id.slice(0, 8)}</span>
                <span className="tabular-nums text-ink">
                  {(p.amountCents / 100).toLocaleString(undefined, { minimumFractionDigits: 0 })} {p.currency}
                </span>
                <span className="text-ink-2">
                  {p.lastResult ?? "not checked yet"}
                  {p.lastCheckAt && <span className="text-ink-3"> · {new Date(p.lastCheckAt).toLocaleTimeString()}</span>}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}

      {events.length > 0 && (
        <div className="border-t border-line pt-4">
          <p className="text-[13px] font-semibold text-ink">Recent webhook events</p>
          <p className="mb-2 text-[12px] text-ink-3">
            What Xendit has sent us. A failed one shows why — the payment is not lost,
            it retries and reprocesses on its own.
          </p>
          <ul className="space-y-1">
            {events.map((e, i) => (
              <li key={i} className="flex flex-wrap items-baseline gap-x-3 gap-y-0.5 text-[12px]">
                <span className="font-mono text-ink-2">{e.eventType ?? "—"}</span>
                <span className={e.result === "failed" ? "font-medium text-coral" : "text-ink-2"}>
                  {e.result ?? "—"}
                </span>
                {e.result === "failed" && e.error && (
                  <span className="text-ink-3">{e.error}</span>
                )}
                <span className="ml-auto text-ink-3">{new Date(e.receivedAt).toLocaleString()}</span>
              </li>
            ))}
          </ul>
        </div>
      )}

      <form action={offAction} className="border-t border-line pt-4">
        {offState && !offState.ok && <Notice kind="error">{offState.message}</Notice>}
        <button className="text-[13px] text-coral underline underline-offset-4">Disconnect Xendit</button>
      </form>
    </div>
  );
}
