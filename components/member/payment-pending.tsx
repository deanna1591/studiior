"use client";

import { useEffect, useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { holdMinutesLeft, holdLabel } from "@/lib/reservation-hold";
import { haptic } from "@/lib/haptics";
import type { ActionResult } from "@/app/member/actions";

/**
 * Decision 103(c) — a reservation hold is "Payment pending", never booked.
 *
 * A pending_payment comp seat (created when a member starts paying the
 * reservation fee) reads "Payment pending" with the minutes left on the hold,
 * a "Finish paying" button that reopens the payment page, and a plain "Cancel"
 * that releases the hold at once (the existing cancel path for a pending_payment
 * booking). The countdown re-evaluates on a clock so it stays honest without a
 * reload; when the sweep releases the hold the row returns to Book with no
 * notice.
 */

/** The ticking status label, for the row's status slot. */
export function HoldCountdown({ holdUntil }: { holdUntil: string }) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 15000);
    return () => clearInterval(t);
  }, []);
  return <>{holdLabel(holdMinutesLeft(holdUntil, now))}</>;
}

/** The hold actions, for the row's action slot. */
export function PaymentPendingActions({
  occurrenceId, bookingId, cancelBooking, onCancelled, href, label = "Finish paying",
}: {
  occurrenceId: string;
  /** Where the pay button goes. Defaults to the reservation checkout; the
   *  Decision 88 (e) online checkout hold passes /checkout/{occurrence}. */
  href?: string;
  label?: string;
  bookingId: string | null;
  cancelBooking: (prev: ActionResult, fd: FormData) => Promise<ActionResult>;
  /** Optimistic hook so the Book list can drop the row at once. */
  onCancelled?: () => void;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  function cancel() {
    if (!bookingId) return;
    haptic("tap");
    onCancelled?.();
    startTransition(async () => {
      const fd = new FormData();
      fd.set("booking_id", bookingId);
      await cancelBooking(null as unknown as ActionResult, fd);
      router.refresh();
    });
  }
  return (
    <span className="flex flex-col items-stretch gap-1.5">
      <Link href={href ?? `/reserve/${occurrenceId}`}
            className="m-tap m-press w-full rounded-full px-4 text-center text-[13px] font-bold"
            style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
        {label}
      </Link>
      <button type="button" onClick={cancel} disabled={pending}
              className="m-tap m-press text-center text-[13px] text-ink-2 underline decoration-line-2 underline-offset-4 disabled:opacity-50">
        Cancel
      </button>
    </span>
  );
}
