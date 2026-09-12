"use client";

import { Fragment, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import ClassCard from "./class-card";
import { haptic } from "@/lib/haptics";
import type { BookResult, ActionResult } from "@/app/member/actions";

/**
 * The day's classes, booked and cancelled OPTIMISTICALLY.
 *
 * The card changes the instant a finger lands — a tap on Book flips the row to
 * booked (the ring, the "Booked", the Cancel action) before the round trip
 * returns, and a buzz confirms it. If the server refuses, the row snaps back
 * and the reason it gave appears above it. That is the whole difference between
 * this feeling like an app and feeling like a form submit that spins.
 *
 * The rules stay on the server. This component receives a fully-resolved
 * descriptor per row — peak-blocked, holding a paid seat, waitlist on or off,
 * the free-cancellation window, whether this is the last peak class of the
 * period — and never recomputes any of it. It only owns the optimistic overlay
 * and the reconciliation, so the peak/flex/publication logic has exactly one
 * home, which is SQL and the page that reads it.
 *
 * The server actions are passed in as props: a server action is a valid prop
 * for a client component, and calling it here rather than through <form action>
 * is what lets the optimistic state lead and the refresh follow.
 */
export type Row = {
  id: string;
  bookingId: string | null;
  name: string;
  href: string;
  startLabel: string;
  endLabel: string | null;
  durationLabel: string;
  instructor: string | null;
  room: string | null;
  isPeak: boolean;
  /** The resolved state the server computed for this row. */
  base: "none" | "booked" | "waiting" | "holding" | "full" | "past" | "peakBlocked";
  spaces: number;
  waitlistPosition: number | null;
  waitlistEnabled: boolean;
  /** Ask before spending the last peak class of the period. */
  confirmLast: boolean;
  /** For a booked peak class: what cancelling costs, said before they tap it. */
  peakCancelNote: string | null;
};

type Override = "booked" | "waiting" | "cancelled" | null;

export default function DayClasses({
  rows,
  bookClass,
  cancelBooking,
  startCheckout,
  payAtDesk,
}: {
  rows: Row[];
  bookClass: (p: BookResult, f: FormData) => Promise<BookResult>;
  cancelBooking: (p: ActionResult, f: FormData) => Promise<ActionResult>;
  startCheckout: (p: ActionResult, f: FormData) => Promise<ActionResult>;
  payAtDesk: (p: ActionResult, f: FormData) => Promise<ActionResult>;
}) {
  const router = useRouter();
  // Per-row optimistic overlay and the last error the server returned for it.
  const [override, setOverride] = useState<Record<string, Override>>({});
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [, startTransition] = useTransition();

  function effectiveState(r: Row): Row["base"] {
    const o = override[r.id];
    if (o === "booked") return "booked";
    if (o === "waiting") return "waiting";
    if (o === "cancelled") return r.base === "waiting" ? "none" : "none";
    return r.base;
  }

  function clearError(id: string) {
    setErrors((e) => (e[id] ? { ...e, [id]: "" } : e));
  }

  function book(r: Row, asWaitlist: boolean) {
    if (r.confirmLast && !asWaitlist && !window.confirm(
      "This is your last peak class for this period. Book it?")) return;
    clearError(r.id);
    // The optimistic flip, in the same frame as the tap.
    setOverride((s) => ({ ...s, [r.id]: asWaitlist ? "waiting" : "booked" }));
    haptic("success");
    startTransition(async () => {
      const fd = new FormData();
      fd.set("occurrence_id", r.id);
      const res = await bookClass(null, fd);
      if (res && res.ok === false) {
        // Snap back and say why.
        setOverride((s) => ({ ...s, [r.id]: null }));
        setErrors((e) => ({ ...e, [r.id]: res.message }));
        haptic("warning");
      } else {
        // Let the server become the source of truth again.
        router.refresh();
        setOverride((s) => ({ ...s, [r.id]: null }));
      }
    });
  }

  function cancel(r: Row) {
    clearError(r.id);
    setOverride((s) => ({ ...s, [r.id]: "cancelled" }));
    haptic("tap");
    startTransition(async () => {
      const fd = new FormData();
      fd.set("booking_id", r.bookingId ?? "");
      const res = await cancelBooking(null, fd);
      if (res && res.ok === false) {
        setOverride((s) => ({ ...s, [r.id]: null }));
        setErrors((e) => ({ ...e, [r.id]: res.message }));
        haptic("warning");
      } else {
        router.refresh();
        setOverride((s) => ({ ...s, [r.id]: null }));
      }
    });
  }

  return (
    <ul className="space-y-3">
      {rows.map((r) => {
        const state = effectiveState(r);
        const err = errors[r.id];

        const statusLabel =
          state === "booked" ? "Booked"
          : state === "holding" ? "Holding your spot"
          : state === "waiting" ? <>You&rsquo;re #<span className="num">{r.waitlistPosition}</span> on the list</>
          : state === "past" ? "This one has started"
          : state === "full" ? "Fully booked"
          // A peak-blocked row keeps its real seat count as its status — the
          // action carries the reason it cannot be booked.
          : <><span className="num">{r.spaces}</span> left</>;

        const statusTone: "quiet" | "booked" | "full" | "holding" =
          state === "booked" ? "booked"
          : state === "holding" ? "holding"
          : state === "full" ? "full"
          : "quiet";

        let action: React.ReactNode = null;
        if (state === "past") action = null;
        else if (state === "peakBlocked") {
          action = (
            <span className="m-meta max-w-[7.5rem] text-right leading-[15px] text-ink-2">
              No peak classes left this period
            </span>
          );
        } else if (state === "holding") {
          // Rare (a Stripe studio, mid-payment). Not optimistic — real money is
          // in flight — so these post as ordinary forms.
          action = (
            <span className="flex flex-col items-end gap-1.5">
              <form action={(fd) => { startCheckout(null, fd); }}>
                <input type="hidden" name="kind" value="dropin" />
                <input type="hidden" name="booking_id" value={r.bookingId ?? ""} />
                <button className="m-tap m-press min-w-[84px] rounded-full px-4 text-[13px] font-bold"
                        style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
                  Pay now
                </button>
              </form>
              <form action={(fd) => { payAtDesk(null, fd); }}>
                <input type="hidden" name="booking_id" value={r.bookingId ?? ""} />
                <button className="m-tap m-press text-ink-2 underline decoration-line-2 underline-offset-4 text-[13px]">
                  Pay at the studio
                </button>
              </form>
            </span>
          );
        } else if (state === "booked" || state === "waiting") {
          action = (
            <span className="flex flex-col items-end gap-1">
              <button
                type="button"
                onClick={() => cancel(r)}
                style={{ background: "var(--accent-chip)", color: "var(--ink)" }}
                className="m-tap m-press min-w-[84px] rounded-full px-4 text-[13px] font-bold"
              >
                {state === "booked" ? "Cancel" : "Leave list"}
              </button>
              {state === "booked" && r.peakCancelNote && (
                <span className="m-micro max-w-[8.5rem] text-right leading-[14px] text-ink-2">
                  {r.peakCancelNote}
                </span>
              )}
            </span>
          );
        } else if (state === "full") {
          action = r.waitlistEnabled ? (
            <button
              type="button"
              onClick={() => book(r, true)}
              style={{ background: "var(--accent-chip)", color: "var(--ink)" }}
              className="m-tap m-press min-w-[84px] rounded-full px-4 text-[13px] font-bold"
            >
              Join waitlist
            </button>
          ) : null;
        } else {
          action = (
            <button
              type="button"
              onClick={() => book(r, false)}
              style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
              className="m-tap m-press min-w-[84px] rounded-full px-4 text-[13px] font-bold"
            >
              Book
            </button>
          );
        }

        return (
          // A Fragment, not a wrapping <li>: ClassCard *is* the <li>, so the
          // optional error note is its own sibling <li> rather than an <li>
          // nested in an <li> (which is invalid and a hydration error).
          <Fragment key={r.id}>
            {err && (
              <li className="m-sub border-l-[3px] px-3 py-2 text-ink list-none"
                 role="status"
                 style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}>
                {err}
              </li>
            )}
            <ClassCard
              href={r.href}
              tag={r.isPeak ? <span className="m-micro mt-0.5 block whitespace-nowrap text-lime-text">Peak</span> : null}
              startLabel={r.startLabel}
              endLabel={r.endLabel}
              durationLabel={r.durationLabel}
              name={r.name}
              instructor={r.instructor}
              room={r.room}
              statusLabel={statusLabel}
              statusTone={statusTone}
              action={action}
              booked={state === "booked"}
              dimmed={state === "past" || state === "peakBlocked"}
            />
          </Fragment>
        );
      })}
    </ul>
  );
}
