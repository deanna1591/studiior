"use client";

import { Fragment, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import ClassCard from "./class-card";
import ClassButton from "./class-button";
import { haptic } from "@/lib/haptics";
import type { BookResult, ActionResult, CheckInResult } from "@/app/member/actions";

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
  /** Raw booking status ('booked' | 'waitlisted' | 'attended' | …), for the
   *  Decision 68 four-state button. */
  bookingStatus: string | null;
  /** Decision 68: checked in (here, at the door, or by a scan). */
  checkedIn: boolean;
  /** Decision 21: a booked flex class still awaiting its cutoff. */
  flexPending: boolean;
  /** The flex cutoff as a short label ("20:00 Sat"), or null for a free-first
   *  PROVISIONAL seat (which has no fixed deadline) — so the two "Waiting for
   *  confirmation" states read differently. */
  pendingLabel: string | null;
  /** Raw ISO instants — the button opens/closes the check-in window on a clock. */
  startsAt: string;
  endsAt: string | null;
  /** Whether the geofenced self check-in can run (the location has coordinates
   *  or does not require them); otherwise the button falls back to the desk code. */
  selfCheckinAvailable: boolean;
  name: string;
  href: string;
  startLabel: string;
  endLabel: string | null;
  durationLabel: string;
  instructor: string | null;
  room: string | null;
  isPeak: boolean;
  /** The resolved state the server computed for this row. */
  base: "none" | "booked" | "waiting" | "holding" | "full" | "past" | "peakBlocked" | "future";
  spaces: number;
  waitlistPosition: number | null;
  waitlistEnabled: boolean;
  /** §4.2: seats a live waitlist offer is holding — a full class with a
   *  physically free seat, so the status can say WHY it is full. */
  heldSeats: number;
  /** Ask before spending the last peak class of the period. */
  confirmLast: boolean;
  /** For a booked peak class: what cancelling costs, said before they tap it. */
  peakCancelNote: string | null;
  /** Decision 30 / booking window: for a class too far ahead to book yet, the
   *  date it opens for booking — shown instead of a Book button. */
  opensOn: string | null;
};

type Override = "booked" | "waiting" | "cancelled" | null;

export default function DayClasses({
  rows,
  bookClass,
  bookFirstFree,
  freeFirstEligible,
  selfCheckIn,
  startCheckout,
  payAtDesk,
  opensBeforeMin,
  closesAfterMin,
}: {
  rows: Row[];
  bookClass: (p: BookResult, f: FormData) => Promise<BookResult>;
  bookFirstFree: (p: BookResult, f: FormData) => Promise<BookResult>;
  freeFirstEligible: boolean;
  selfCheckIn: (bookingId: string, lat: number | null, lng: number | null, accuracy: number | null) => Promise<CheckInResult>;
  startCheckout: (p: ActionResult, f: FormData) => Promise<ActionResult>;
  payAtDesk: (p: ActionResult, f: FormData) => Promise<ActionResult>;
  opensBeforeMin: number;
  closesAfterMin: number;
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
      // Decision 30: an eligible member's booking IS the free class — the same
      // button, the free path. Never the paid drop-in that book_class would
      // resolve for a lead. (Waitlisting a full class is never the free path.)
      const res = await (freeFirstEligible && !asWaitlist
        ? bookFirstFree(null, fd)
        : bookClass(null, fd));
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
          : state === "full"
            ? (r.heldSeats > 0
                ? <>Full · <span className="num">{r.heldSeats}</span> on hold</>
                : "Fully booked")
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
        else if (state === "future") {
          // Too far ahead to book yet — say when it opens, rather than a Book
          // button that would refuse on tap.
          action = (
            <span className="m-meta max-w-[8.5rem] text-right leading-[15px] text-ink-2">
              Opens for booking {r.opensOn}
            </span>
          );
        }
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
          // Decision 68: one button carries where the member is —
          // Reserved → Check in now → Checked in (or Waiting for a flex class,
          // Waitlisted for a waitlist seat). Tapping Reserved / Waitlisted opens
          // the class page, where Cancel lives.
          action = (
            <ClassButton
              occurrenceId={r.id}
              bookingId={r.bookingId}
              classHref={r.href}
              bookingStatus={state === "booked" ? "booked" : "waitlisted"}
              flexPending={r.flexPending}
              pendingLabel={r.pendingLabel}
              checkedIn={r.checkedIn}
              startsAt={r.startsAt}
              endsAt={r.endsAt}
              opensBeforeMin={opensBeforeMin}
              closesAfterMin={closesAfterMin}
              waitlistPosition={r.waitlistPosition}
              selfCheckinAvailable={r.selfCheckinAvailable}
              bookClass={bookClass}
              bookFirstFree={bookFirstFree}
              selfCheckIn={selfCheckIn}
            />
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
          // Decision 30: for an eligible member, this book IS the free class.
          // Decision 68: Book is the light accent tint (the solid accent is
          // reserved for "Check in now", the one urgent action).
          action = (
            <button
              type="button"
              onClick={() => book(r, false)}
              style={{ background: "var(--accent-chip)", color: "var(--ink)" }}
              className="m-tap m-press min-w-[84px] rounded-full px-4 text-[13px] font-bold"
            >
              {freeFirstEligible ? "Book free" : "Book"}
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
