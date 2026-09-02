"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice } from "@/components/ui";
import { applyForShift, approveApplication, declineApplication, withdrawFromShift, type ShiftState } from "./actions";

function Btn({ label, tone = "quiet" }: { label: string; tone?: "primary" | "quiet" }) {
  const { pending } = useFormStatus();
  return (
    <button
      disabled={pending}
      className={`shrink-0 rounded-lg px-3 py-1.5 text-[13px] font-medium disabled:opacity-60 ${
        tone === "primary"
          ? "bg-lime text-ink"
          : "border border-line-2 bg-surface text-ink-2"
      }`}
    >
      {pending ? "…" : label}
    </button>
  );
}

export function ApplyForm({ occurrenceId, outside }: { occurrenceId: string; outside: boolean }) {
  const [state, action] = useFormState<ShiftState, FormData>(applyForShift, null);
  return (
    <form action={action} className="shrink-0 text-right">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      <Btn label={outside ? "Ask anyway" : "Ask for it"} tone="primary" />
    </form>
  );
}

export function DecideForm({ applicationId }: { applicationId: string }) {
  const [approveState, approve] = useFormState<ShiftState, FormData>(approveApplication, null);
  const [declineState, decline] = useFormState<ShiftState, FormData>(declineApplication, null);
  const state = approveState ?? declineState;
  return (
    <div className="shrink-0">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="flex gap-2">
        <form action={approve}>
          <input type="hidden" name="application_id" value={applicationId} />
          <Btn label="Approve" tone="primary" />
        </form>
        <form action={decline}>
          <input type="hidden" name="application_id" value={applicationId} />
          <Btn label="Decline" />
        </form>
      </div>
    </div>
  );
}

export function WithdrawForm({ occurrenceId }: { occurrenceId: string }) {
  const [state, action] = useFormState<ShiftState, FormData>(withdrawFromShift, null);
  return (
    <form action={action} className="shrink-0 text-right">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      <Btn label="I can't make it" />
    </form>
  );
}
