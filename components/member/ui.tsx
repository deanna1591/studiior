"use client";

import { useFormState, useFormStatus } from "react-dom";
import type { ActionResult, BookResult } from "@/app/member/actions";

export function Note({ ok, children }: { ok: boolean; children: React.ReactNode }) {
  return (
    <p
      className="m-sub mb-3 border-l-[3px] px-3 py-2 text-ink"
      style={{
        borderLeftColor: ok ? "var(--lime-text)" : "var(--coral)",
        background: ok ? "var(--lime-tint)" : "var(--coral-tint)",
      }}
      role="status"
    >
      {children}
    </p>
  );
}

/** The one big button. 56px, lime, and only ever one per screen. */
export function PrimaryButton({ children }: { children: React.ReactNode }) {
  const { pending } = useFormStatus();
  return (
    <button
      disabled={pending}
      className="m-action w-full rounded-lg bg-lime px-4 text-[16px] font-medium text-ink disabled:opacity-60"
    >
      {pending ? "One moment…" : children}
    </button>
  );
}

export function QuietButton({ children }: { children: React.ReactNode }) {
  const { pending } = useFormStatus();
  return (
    <button
      disabled={pending}
      className="m-tap inline-flex items-center rounded-lg border border-line-2 bg-surface px-4 text-[14px] text-ink disabled:opacity-60"
    >
      {pending ? "…" : children}
    </button>
  );
}

/** A form bound to one of the member actions, with its own reply above it. */
export function ActionForm({
  action, children, className = "",
}: {
  action: (p: ActionResult, f: FormData) => Promise<ActionResult>;
  children: React.ReactNode;
  className?: string;
}) {
  const [state, run] = useFormState<ActionResult, FormData>(action, null);
  return (
    <form action={run} className={className}>
      {state && <Note ok={state.ok}>{state.message}</Note>}
      {children}
    </form>
  );
}

export function BookForm({
  action, children, className = "",
}: {
  action: (p: BookResult, f: FormData) => Promise<BookResult>;
  children: React.ReactNode;
  className?: string;
}) {
  const [state, run] = useFormState<BookResult, FormData>(action, null);
  return (
    <form action={run} className={className}>
      {state && <Note ok={state.ok}>{state.message}</Note>}
      {children}
    </form>
  );
}
