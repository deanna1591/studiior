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

/**
 * The filled-accent pair, as one style.
 *
 * `bg-lime text-ink` was hard-coded in seven places, which is fine while the
 * accent is Studiior's near-yellow lime and unreadable the moment a studio
 * picks navy: near-black text on a dark fill. --accent-solid and
 * --accent-on-solid are derived together in lib/theme.ts and measured against
 * the preset, so they are always used together and never separately.
 */
export const accentFill = { background: "var(--accent-solid)", color: "var(--accent-on-solid)" };

/** The one big button. 56px, accent-filled, and only ever one per screen. */
export function PrimaryButton({ children }: { children: React.ReactNode }) {
  const { pending } = useFormStatus();
  return (
    <button
      disabled={pending}
      style={accentFill}
      className="m-action w-full rounded-xl px-4 text-[16px] font-semibold disabled:opacity-60"
    >
      {pending ? "One moment…" : children}
    </button>
  );
}

/** The action inside a class card: filled, accent, compact. */
export function CardAction({ children }: { children: React.ReactNode }) {
  const { pending } = useFormStatus();
  return (
    <button
      disabled={pending}
      style={accentFill}
      className="m-tap min-w-[84px] rounded-full px-4 text-[13px] font-bold disabled:opacity-60"
    >
      {pending ? "…" : children}
    </button>
  );
}

/**
 * The outlined counterpart — Cancel, and Join waitlist.
 *
 * Neutral, not coral. The reference sets Cancel in red, but --coral measures
 * 4.47 on white and this project does not darken the brand to make a colour
 * pass; and cancelling here is an ordinary, reversible thing — §3.1 puts the
 * credit back — not a warning. Coral is kept for the states that are actually
 * wrong, like a failed payment.
 */
export function CardActionOutline({ children }: { children: React.ReactNode }) {
  const { pending } = useFormStatus();
  return (
    <button
      disabled={pending}
      // No border. On a white card a hairline is the one thing the redesign
      // removed everywhere else, and an outlined button beside a filled one is
      // two different idioms in the same 44px row. Tint and accent text
      // instead — the same pair the ramp already measures.
      // Ink on the accent's chip, not accent-on-tint. --lime-text is derived
      // by darkening until it clears 4.5 against the SURFACE; the tint is that
      // surface with 12% accent over it, so the same colour lands at 3.88 on
      // it. Ink is measured on both.
      style={{ background: "var(--accent-chip)", color: "var(--ink)" }}
      className="m-tap min-w-[84px] rounded-full px-4 text-[13px] font-bold disabled:opacity-60"
    >
      {pending ? "…" : children}
    </button>
  );
}

export function QuietButton({ children }: { children: React.ReactNode }) {
  const { pending } = useFormStatus();
  return (
    <button
      disabled={pending}
      style={{ background: "var(--accent-chip)", color: "var(--ink)" }}
      className="m-tap inline-flex items-center rounded-full px-4 text-[13px] font-bold disabled:opacity-60"
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
