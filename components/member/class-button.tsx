"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { haptic } from "@/lib/haptics";
import { classButtonState } from "@/lib/class-button";
import type { BookResult, CheckInResult } from "@/app/member/actions";

/**
 * Decision 68 — the one class button, four states.
 *
 * Book → Reserved → Check in now → Checked in, on every class a member can act
 * on (the Book list, the class page, Home's next-class card, Also booked). The
 * state machine is the pure `classButtonState` (node-tested); this component
 * renders it, re-evaluates it on a clock so the check-in window opens on its
 * own, and owns the two actions it can take — book, and the geolocated
 * self_check_in (Decision 35). Cancel is not here: tapping Reserved / Waitlisted
 * opens the class page, where Cancel lives.
 *
 * Non-action states (a full class to join the waitlist for, a holding seat, a
 * peak-blocked or out-of-window row, a past class) stay with the caller — this
 * is the member's own booking lifecycle, not the whole row.
 */
type Tone = "tint" | "scrim";

export default function ClassButton({
  occurrenceId, bookingId, classHref,
  bookingStatus, flexPending, pendingLabel = null, checkedIn, cancelled = false,
  startsAt, endsAt, opensBeforeMin, closesAfterMin,
  waitlistPosition = null,
  full = false, waitlistEnabled = false, freeFirstEligible = false, confirmLast = false,
  selfCheckinAvailable = true, deskCodeHref = "/check-in",
  tone = "tint", checkinOnly = false,
  bookClass, bookFirstFree, selfCheckIn, onChange,
}: {
  occurrenceId: string;
  bookingId: string | null;
  classHref: string;
  bookingStatus: string | null;
  flexPending: boolean;
  /** Decision 21 vs Decision 30: a flex-pending booking carries its cutoff ("by
   *  20:00 Sat"), a free-first PROVISIONAL seat does not (null) — so the two
   *  "Waiting for confirmation" states read differently. Formatted server-side. */
  pendingLabel?: string | null;
  checkedIn: boolean;
  cancelled?: boolean;
  startsAt: string;
  endsAt: string | null;
  opensBeforeMin: number;
  closesAfterMin: number;
  waitlistPosition?: number | null;
  full?: boolean;
  waitlistEnabled?: boolean;
  freeFirstEligible?: boolean;
  confirmLast?: boolean;
  selfCheckinAvailable?: boolean;
  deskCodeHref?: string;
  tone?: Tone;
  /** The class page keeps its own status line and Cancel; it wants only the new
   *  affordance — Check in now / Checked in — and renders nothing for the
   *  reserved / waiting / waitlisted states the page already expresses. */
  checkinOnly?: boolean;
  bookClass: (p: BookResult, f: FormData) => Promise<BookResult>;
  bookFirstFree: (p: BookResult, f: FormData) => Promise<BookResult>;
  selfCheckIn: (bookingId: string, lat: number | null, lng: number | null, accuracy: number | null) => Promise<CheckInResult>;
  onChange?: (booked: boolean) => void;
}) {
  const router = useRouter();
  const [now, setNow] = useState(() => Date.now());
  const [optimistic, setOptimistic] = useState<"reserved" | "checked_in" | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const busy = useRef(false);

  // Re-evaluate across the window boundary without a reload.
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 30_000);
    return () => clearInterval(id);
  }, []);

  const startsMs = new Date(startsAt).getTime();
  const endsMs = endsAt ? new Date(endsAt).getTime() : null;

  let state = classButtonState({
    bookingStatus, flexPending, checkedIn, cancelled,
    startsMs, endsMs, opensBeforeMin, closesAfterMin, nowMs: now,
  });
  // The optimistic flip leads the round trip; the server becomes the truth on refresh.
  if (optimistic === "reserved" && state === "book")
    state = classButtonState({ bookingStatus: "booked", flexPending, checkedIn: false,
      startsMs, endsMs, opensBeforeMin, closesAfterMin, nowMs: now });
  if (optimistic === "checked_in") state = "checked_in";

  // --- actions ---------------------------------------------------------------
  function doBook() {
    if (confirmLast && !window.confirm("This is your last peak class for this period. Book it?")) return;
    setMsg(null);
    setOptimistic("reserved");
    onChange?.(true);
    haptic("success");
    start(async () => {
      const fd = new FormData();
      fd.set("occurrence_id", occurrenceId);
      const res = await (freeFirstEligible ? bookFirstFree(null, fd) : bookClass(null, fd));
      if (res && res.ok === false) {
        setOptimistic(null);
        onChange?.(false);
        setMsg(res.message);
        haptic("warning");
      } else {
        router.refresh();
        setOptimistic(null);
      }
    });
  }

  function runCheckIn(lat: number | null, lng: number | null, accuracy: number | null) {
    if (!bookingId) return;
    start(async () => {
      const r = await selfCheckIn(bookingId, lat, lng, accuracy);
      if (r?.ok) {
        setOptimistic("checked_in");
        haptic("success");
        router.refresh();
      } else {
        busy.current = false;
        setMsg(r?.message ?? "You couldn't be checked in — show your code at the desk.");
        haptic("warning");
      }
    });
  }

  function doCheckIn() {
    if (busy.current) return;
    busy.current = true;
    setMsg(null);
    if (typeof navigator === "undefined" || !navigator.geolocation) { runCheckIn(null, null, null); return; }
    navigator.geolocation.getCurrentPosition(
      (p) => runCheckIn(p.coords.latitude, p.coords.longitude, p.coords.accuracy),
      () => runCheckIn(null, null, null),   // denied / unavailable: server decides
      { enableHighAccuracy: true, timeout: 10_000, maximumAge: 0 },
    );
  }

  // --- styles ----------------------------------------------------------------
  const pill = "m-tap m-press inline-flex min-w-[84px] items-center justify-center rounded-full px-4 text-[13px] font-bold disabled:opacity-90";
  const chip = "inline-flex min-w-[84px] items-center justify-center rounded-full px-4 py-2 text-[13px] font-bold";
  const tint = tone === "scrim"
    ? { background: "color-mix(in srgb, #FFFFFF 22%, transparent)", color: "#FFFFFF" }
    : { background: "var(--accent-chip)", color: "var(--ink)" };
  const solid = { background: "var(--accent-solid)", color: "var(--accent-on-solid)" };
  const grey = tone === "scrim"
    ? { background: "color-mix(in srgb, #FFFFFF 18%, transparent)", color: "#FFFFFF" }
    : { background: "var(--line)", color: "var(--ink-2)" };

  // The reason as a sentence. On a row it sits right under the button; over the
  // hero scrim it is a bottom toast (where there is no room beneath the button).
  const reason = msg
    ? tone === "scrim"
      ? (
        <div className="fixed inset-x-0 bottom-[92px] z-50 flex justify-center px-4" role="status">
          <p className="m-card max-w-sm px-4 py-3 text-center text-[14px] leading-5 text-ink">{msg}</p>
        </div>
      ) : (
        <span className="m-micro mt-1 block max-w-[10rem] text-right leading-[15px] text-ink-2" role="status">{msg}</span>
      )
    : null;

  const wrap = (node: React.ReactNode) =>
    tone === "scrim"
      ? <>{node}{reason}</>
      : <span className="flex flex-col items-end gap-1">{node}{reason}</span>;

  // The class page supplies its own everything except the check-in affordance.
  if (checkinOnly && state !== "checkin" && state !== "checked_in") return null;

  if (state === "cancelled") {
    return wrap(<span className={chip} style={grey}>Cancelled</span>);
  }
  if (state === "book") {
    const label = freeFirstEligible ? "Book free" : full && waitlistEnabled ? "Join waitlist" : "Book";
    if (full && !waitlistEnabled) return null;
    return wrap(
      <button type="button" onClick={doBook} disabled={pending} className={pill} style={tint}>
        {pending ? "…" : label}
      </button>,
    );
  }
  if (state === "waitlisted") {
    return wrap(
      <Link href={classHref} className={`${pill} m-press`} style={tint}>
        Waitlisted{waitlistPosition != null && <> · #<span className="num ml-0.5">{waitlistPosition}</span></>}
      </Link>,
    );
  }
  if (state === "waiting_confirmation") {
    // A flex-pending booking shows its cutoff ("· by 20:00 Sat"); a free-first
    // PROVISIONAL seat (pendingLabel null) stays bare, since it confirms the
    // moment the class is on, not at a fixed deadline. The two states then read
    // differently rather than both saying only "Waiting for confirmation".
    return wrap(
      <span className="flex flex-col items-end gap-0.5">
        <span className={`${chip} text-center leading-[15px]`} style={tint}>Waiting for confirmation</span>
        {pendingLabel && (
          <span className="m-micro leading-[15px] text-ink-2">
            by <span className="num">{pendingLabel}</span>
          </span>
        )}
      </span>,
    );
  }
  if (state === "checked_in") {
    return wrap(<span className={chip} style={grey}>Checked in</span>);
  }
  if (state === "checkin") {
    // Where the geofence can't place the phone, fall back to the rotating code.
    if (!selfCheckinAvailable) {
      return wrap(<Link href={deskCodeHref} className={pill} style={solid}>Check in now</Link>);
    }
    return wrap(
      <button type="button" onClick={doCheckIn} disabled={pending} className={pill} style={solid}>
        {pending ? "Checking in…" : "Check in now"}
      </button>,
    );
  }
  // reserved — not tappable; tapping opens the class page where Cancel lives.
  return wrap(
    <Link href={classHref} className={`${pill} m-press`} style={tint}>Reserved</Link>,
  );
}
