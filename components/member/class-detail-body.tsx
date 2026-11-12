import { focalPoint } from "@/lib/focal";
import Avatar from "@/components/member/avatar";
import { Icon } from "@/components/member/icons";
import IconChip from "@/components/member/icon-chip";
import { BookForm, ActionForm, PrimaryButton, CardActionOutline } from "@/components/member/ui";
import Link from "next/link";
import { bookClass, bookFirstFree, cancelBooking, selfCheckIn } from "@/app/member/actions";
import ClassButton from "@/components/member/class-button";
import CancelButton from "@/components/member/cancel-button";
import type { SeatKind } from "@/lib/cancel-notice";
import DuplicateHold from "@/components/member/duplicate-hold";
import { classSheetView, bookRoute } from "@/lib/class-sheet";
import { flexWaitingLabel } from "@/lib/class-button";
import GuestInvite from "@/components/member/guest-invite";
import type { FreeFirst, Pending } from "@/app/member/class/[id]/load";
import { fmtTime, fmtDayLong, fmtDeadlineShort } from "@/lib/time";

/**
 * One class, in full — the body shared by the full page (`/class/[id]`) and the
 * bottom sheet that intercepts a tap from within the app. Same markup either
 * way, so the sheet and the page can never drift; the only difference is the
 * frame around it, which each caller supplies.
 *
 * It takes the already-fetched rows rather than fetching, because the two
 * callers fetch through their own request-scoped, RLS-bound client and this
 * component must not open a third path to the data.
 */
export type DetailOccurrence = {
  id: string;
  name: string;
  starts_at: string;
  ends_at: string | null;
  capacity: number;
  booked_count: number;
  waitlist_count: number | null;
  rooms: { name: string | null } | null;
  instructors: {
    display_name: string;
    bio: string | null;
    avatar_url: string | null;
    certifications: unknown;
  } | null;
};
export type DetailType = {
  name: string | null;
  description: string | null;
  image_url: string | null;
  image_focus_x: number | null;
  image_focus_y: number | null;
} | null;
export type DetailBooking = { id: string; status: string; waitlist_position: number | null } | null;

export default function ClassDetailBody({
  occ, type, booking, timeZone, timeFormat, waitlistEnabled, guest, freeFirst, pending,
  checkedIn = false, checkedInAt = null, selfCheckinAvailable = false, opensBeforeMin = 60, closesAfterMin = 30,
  unpaid = false, group = null, deskPayAvailable = true, covered = true, waiverBlocked = false,
  seatKind = "unlimited", cutoffMinutes = 720, duplicateHold = false, holdTime = null,
}: {
  occ: DetailOccurrence;
  type: DetailType;
  booking: DetailBooking;
  timeZone: string;
  timeFormat?: "24h" | "12h";
  waitlistEnabled: boolean;
  guest?: { enabled: boolean; canInvite: boolean };
  freeFirst?: FreeFirst;
  /** Decision 21 amendment: a flex class not yet decided — its confirmation
   *  deadline and how it is expressed. Null for core/always/decided classes. */
  pending?: Pending;
  /** Decision 68: checked in by any door; whether self check-in can run; and
   *  the studio's check-in window, so the page can offer "Check in now". */
  checkedIn?: boolean;
  /** FIX A: when the member checked in, for the "You're checked in · {time}" line. */
  checkedInAt?: string | null;
  selfCheckinAvailable?: boolean;
  opensBeforeMin?: number;
  closesAfterMin?: number;
  /** Decision 73b: this booking is an unpaid drop-in (a booked seat with no
   *  payment). When set, the page offers two ways to pay. */
  unpaid?: boolean;
  /** Decision 76: this seat is part of a group (Barkada). A guest sees "Booked
   *  by {host}" and no cancel; the host gets a link to manage the group. */
  group?: { isHost: boolean; host: string; plan: string; groupId: string } | null;
  /** Decision 73 (c): can this member still pay at the desk? When false, the
   *  page hides the pay-at-the-desk option and tells them to pay online. */
  deskPayAvailable?: boolean;
  /** Decision 98: this seat is a held free-class duplicate — the paid-or-lose
   *  line + checkout button, with the hold deadline. */
  duplicateHold?: boolean;
  holdTime?: string | null;
  /** Decision 88: does this member's plan cover the class? When true, Book books
   *  inline (unchanged); when false, Book opens /checkout to pick a plan and pay. */
  covered?: boolean;
  /** Decision 35 amendment: the studio waiver is unsigned, so the "Sign the
   *  waiver" notice shows above the check-in button, which is disabled. */
  waiverBlocked?: boolean;
  /** Decision 36 amendment: this booked seat's cancel-wording bucket, and the
   *  studio's cancellation cutoff (minutes) — the before-the-tap line reads from
   *  both. Computed server-side in load.ts / from member_bootstrap. */
  seatKind?: SeatKind;
  cutoffMinutes?: number;
}) {
  const spaces = occ.capacity - occ.booked_count;
  const full = spaces <= 0;
  const past = new Date(occ.starts_at).getTime() < Date.now();
  // Decision 75a: a no-show booking reads "Did not attend" — no capacity, no action.
  const noShow = booking?.status === "no_show";

  // FIX A: the member's OWN relationship to the class wins over capacity — the
  // same resolver the schedule uses. attended → checked_in (grey, no actions);
  // booked → checkin (in window) / reserved (outside); waitlisted → leave.
  const view = classSheetView({
    bookingStatus: booking?.status ?? null,
    flexPending: !!(pending && pending.until),
    checkedIn,
    startsMs: new Date(occ.starts_at).getTime(),
    endsMs: occ.ends_at ? new Date(occ.ends_at).getTime() : null,
    opensBeforeMin, closesAfterMin,
    full, waitlistEnabled,
    freeFirstEligible: freeFirst?.eligible === true,
  });
  const isCheckedIn = view.state === "checked_in";
  const isWaitlisted = view.state === "waitlisted";
  // An actionable booking (not a completed check-in): checkin / reserved /
  // waiting_confirmation / waitlisted.
  const hasBooking = view.hideCapacity && !isCheckedIn;
  // Decision 88 addendum: where "Book" goes for a member with no live booking —
  // free-first first (Decision 30), then full, then covered-inline vs /checkout.
  // The one precedence, in a tested helper so a reorder cannot silently send an
  // eligible member to checkout.
  const route = bookRoute({ freeFirstEligible: freeFirst?.eligible === true, full, waitlistEnabled, covered });

  // Decision 21 amendment (20 Oct 2026): the member-facing confirmation copy —
  // always about THEIR booking, in plain words, never a minimum or a headcount.
  // The class page gets ONE grey line (why a small class may wait, reassuringly,
  // no numbers); and the plain-words status once booked. Decision 30: a free
  // PROVISIONAL booking is pending with no time (mode 'free', until null) — it
  // confirms the moment the class is on, so the grey line (which speaks of a
  // deadline) shows only for a flex class with a cutoff.
  const confirmLine = pending && !past && pending.until
    ? "Small classes go ahead once a few people have booked. Most are confirmed well before the deadline."
    : null;
  const waitingLabel = pending && !past
    ? flexWaitingLabel(pending.until ? fmtDeadlineShort(pending.until, timeZone, timeFormat) : null)
    : null;
  const mins = occ.ends_at
    ? Math.round((new Date(occ.ends_at).getTime() - new Date(occ.starts_at).getTime()) / 60000)
    : null;

  const instructor = occ.instructors;
  const certs = Array.isArray(instructor?.certifications)
    ? (instructor!.certifications as string[]).filter(Boolean)
    : [];

  return (
    <>
      {type?.image_url && (
        // eslint-disable-next-line @next/next/no-img-element
        // Perf (1 Nov): the class hero is the above-the-fold LCP — eager + async
        // decode; width/height are a hint (the h-52 box + object-cover decide the
        // render, so no visual change).
        <img src={type.image_url} alt="" aria-hidden
             loading="eager" decoding="async" width={1024} height={208}
             className="mb-4 h-52 w-full rounded-[22px] object-cover"
             style={{ maxWidth: "100%", objectPosition: focalPoint(type.image_focus_x, type.image_focus_y) }} />
      )}

      <h1 className="m-title text-ink">{occ.name}</h1>

      <div className="mt-3 flex flex-wrap items-center gap-x-2 gap-y-1">
        <span className="num text-[16px] font-semibold text-ink">
          {fmtTime(occ.starts_at, timeZone, timeFormat)}
          {occ.ends_at && <> – {fmtTime(occ.ends_at, timeZone, timeFormat)}</>}
        </span>
        {mins && (
          <span className="rounded-full px-2 py-0.5 text-[11px] leading-4 text-ink-2" style={{ background: "var(--accent-chip)" }}>
            <span className="num">{mins}</span> mins
          </span>
        )}
      </div>
      <p className="m-sub mt-1 text-ink-2">{fmtDayLong(occ.starts_at, timeZone)}</p>
      {occ.rooms?.name && (
        <p className="m-meta mt-3 flex items-center gap-2.5 text-ink-2">
          <IconChip name="door" /> {occ.rooms.name}
        </p>
      )}

      <div className="m-card mt-4 p-4">
        {/* FIX A: the member's own status wins over capacity. checked_in is a
            greyed, non-clickable line with the check-in time; the capacity line
            is hidden for anyone with their own booking. */}
        <p className="m-sub mb-3 text-ink-2">
          {noShow ? "Did not attend"
            : past && !view.hideCapacity ? "This class has already started."
            : isCheckedIn ? <>You&rsquo;re checked in{checkedInAt && <> · <span className="num">{fmtTime(checkedInAt, timeZone, timeFormat)}</span></>}</>
            : isWaitlisted ? <>You&rsquo;re #<span className="num">{booking!.waitlist_position}</span> on the waitlist.</>
            : hasBooking ? (waitingLabel ?? "You're booked in.")
            : full ? <>Fully booked{(occ.waitlist_count ?? 0) > 0 && <> · <span className="num">{occ.waitlist_count}</span> waiting</>}</>
            : <><span className="num font-medium text-ink">{spaces}</span> {spaces === 1 ? "place" : "places"} left</>}
        </p>

        {/* Decision 21 amendment: the confirmation deadline, shown before booking
            on a flex class not yet decided. m-sub, no icon, no badge. */}
        {confirmLine && !view.hideCapacity && (
          <p className="m-sub mb-3 text-ink-3">{confirmLine}</p>
        )}

        {past || isCheckedIn ? null : hasBooking ? (
          <>
            {/* Decision 68: the one button — but the page keeps its own status
                line and Cancel, so here it adds only the new affordance:
                Check in now (in the window). Nothing for the plain reserved /
                waiting states the line above already expresses. */}
            {/* Decision 35 amendment: waiver unsigned → the "Sign the waiver"
                notice above the check-in button, which stays visible but disabled. */}
            {waiverBlocked && (
              <div className="m-card mb-3 p-4 text-left"
                   style={{ borderLeft: "3px solid var(--coral)", background: "var(--coral-tint)" }}>
                <p className="m-body text-ink">Please sign the waiver first before checking in.</p>
                <Link href={`/waiver?next=${encodeURIComponent(`/class/${occ.id}`)}`}
                      className="m-press mt-2 inline-block rounded-lg px-3 py-1.5 text-[13px] font-semibold"
                      style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
                  Sign the waiver
                </Link>
              </div>
            )}
            <div className="mb-3 flex justify-start empty:hidden">
              <ClassButton
                occurrenceId={occ.id}
                bookingId={booking!.id}
                classHref={`/class/${occ.id}`}
                bookingStatus={isWaitlisted ? "waitlisted" : "booked"}
                flexPending={!!(pending && pending.until)}
                checkedIn={checkedIn}
                startsAt={occ.starts_at}
                endsAt={occ.ends_at}
                opensBeforeMin={opensBeforeMin}
                closesAfterMin={closesAfterMin}
                selfCheckinAvailable={selfCheckinAvailable}
                checkinOnly
                checkinBlocked={waiverBlocked}
                bookClass={bookClass}
                bookFirstFree={bookFirstFree}
                selfCheckIn={selfCheckIn}
              />
            </div>
            {/* Decision 76: a GROUP seat is never individually cancelled. A
                guest sees who booked them and is told to ask the host; the host
                gets a link to manage the whole group (names, swap, cancel). */}
            {group ? (
              group.isHost ? (
                <div className="m-card p-3" style={{ background: "var(--accent-chip)" }}>
                  <p className="text-[14px] font-medium leading-5 text-ink">You booked this for your group</p>
                  <p className="m-sub mt-0.5 text-ink-2">{group.plan}</p>
                  <Link href={`/group/${group.groupId}`}
                        className="m-press mt-2 inline-block text-[13px] text-ink underline underline-offset-4">
                    Manage this group
                  </Link>
                </div>
              ) : (
                <div className="m-card p-3">
                  <p className="text-[14px] leading-5 text-ink">Booked by {group.host} · {group.plan}</p>
                  <p className="m-sub mt-0.5 text-ink-3">Ask {group.host} if you can&rsquo;t make it.</p>
                </div>
              )
            ) : isWaitlisted ? (
              // Leaving a waitlist is free and unconditional (§4.1) — no notice.
              <ActionForm action={cancelBooking}>
                <input type="hidden" name="booking_id" value={booking!.id} />
                <CardActionOutline>Leave the list</CardActionOutline>
              </ActionForm>
            ) : (
              <>
                {/* Decision 36 amendment: the cancel rule is shown before the tap —
                    the seat-specific line under the button, a confirm sheet once
                    inside the cutoff, and the seat-specific result after. */}
                <CancelButton
                  bookingId={booking!.id}
                  seatKind={seatKind}
                  startsAt={occ.starts_at}
                  cutoffMinutes={cutoffMinutes}
                  timeZone={timeZone}
                  timeFormat={timeFormat}
                  cancel={cancelBooking}
                />
                <a href={`/class/${occ.id}/ics`}
                   className="m-press mt-2 block text-center text-[13px] leading-[18px] text-ink-2 underline underline-offset-4">
                  Add to calendar
                </a>
              </>
            )}
          </>
        ) : route === "free" ? (
          // Decision 30 (88 addendum: free-first comes first): this member's first
          // class is free. Said plainly right where they decide, and the Book books
          // it at zero — no plan, no card, never the checkout.
          <BookForm action={bookFirstFree}>
            <input type="hidden" name="occurrence_id" value={occ.id} />
            <p className="mb-2.5 rounded-xl px-3 py-2 text-[13px] leading-[18px] text-ink"
               style={{ background: "var(--accent-chip)" }}>
              <span className="font-semibold">Your first class is on us.</span> No card, no plan — just book it.
            </p>
            <PrimaryButton>Book — first class free</PrimaryButton>
          </BookForm>
        ) : route === "waitlist" ? (
          <BookForm action={bookClass}>
            <input type="hidden" name="occurrence_id" value={occ.id} />
            <PrimaryButton>Join the waitlist</PrimaryButton>
            <p className="m-micro mt-1.5 text-center text-ink-3">
              No class is used unless a place opens and you take it.
            </p>
          </BookForm>
        ) : route === "full" ? (
          <p className="m-sub text-ink-3">This class is full and has no waitlist.</p>
        ) : route === "book" ? (
          // Decision 88: a plan covers this class, so Book still books inline.
          <BookForm action={bookClass}>
            <input type="hidden" name="occurrence_id" value={occ.id} />
            <PrimaryButton>Book this class</PrimaryButton>
          </BookForm>
        ) : (
          // Decision 88: no plan covers this class — Book opens checkout, where
          // they pick a plan, see the cost, and pay (or pay at the desk there).
          <Link href={`/checkout/${occ.id}`}
                style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
                className="m-action m-press flex w-full items-center justify-center rounded-xl text-[16px] font-semibold">
            Book this class
          </Link>
        )}
      </div>

      {/* Decision 98: a free class re-flagged as a duplicate — the paid-or-lose
          line + checkout button, with its own deadline. */}
      {duplicateHold && !past && (
        <DuplicateHold occurrenceId={occ.id} className={occ.name} holdTime={holdTime} />
      )}

      {/* Decision 88: an unpaid drop-in booking — "Pay now" opens checkout
          (Decision 73b's /account/plan path is replaced by it), where buying any
          plan settles this held booking through the Xendit rail on activation;
          "pay at the desk" is informational. */}
      {unpaid && !past && (
        <div className="m-card mt-3 p-4">
          <p className="text-[15px] font-medium leading-5 text-ink">This booking isn&rsquo;t paid yet</p>
          <p className="m-sub mt-1 text-ink-2">
            Pay now to settle it, or pay at the desk when you come in.
          </p>
          <Link href={`/checkout/${occ.id}`}
                style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
                className="m-action m-press mt-3 flex w-full items-center justify-center rounded-xl text-[16px] font-semibold">
            Pay now
          </Link>
          {/* Decision 73 (c): the pay-at-the-desk option is hidden once desk pay
              is off for this member. */}
          <p className="m-sub mt-2 text-ink-3">
            {deskPayAvailable
              ? "Or pay at the desk when you come in."
              : "Paying at the desk is not available on this account."}
          </p>
        </div>
      )}

      {/* Decision 30's conversion moment: they've booked their free class, so
          tell them what comes next rather than leaving the space empty. */}
      {freeFirst?.isFreeBooking && (hasBooking || isCheckedIn) && !past && (
        <Link href="/account/plan" className="m-card m-press mt-3 flex items-center gap-3 p-4">
          <span className="flex-1">
            <span className="block text-[15px] font-medium leading-5 text-ink">This one&rsquo;s on us 🎉</span>
            <span className="m-sub mt-0.5 block text-ink-2">
              Come along, and if you like it, see what a class costs after — the plans are here.
            </span>
          </span>
          <span className="shrink-0 text-ink-3">›</span>
        </Link>
      )}

      {guest?.canInvite && !past && !isWaitlisted && (
        <GuestInvite occurrenceId={occ.id} />
      )}

      {type?.description && (
        <section className="mt-6">
          <h2 className="section-label text-ink-2">About this class</h2>
          <p className="m-body mt-2 whitespace-pre-line text-ink-2">{type.description}</p>
        </section>
      )}

      {instructor && (
        <section className="mt-6">
          <h2 className="section-label text-ink-2">Your instructor</h2>
          <div className="mt-3 flex items-start gap-3">
            <Avatar name={instructor.display_name} url={instructor.avatar_url} size={56} />
            <div className="min-w-0">
              <p className="m-body font-semibold text-ink">{instructor.display_name}</p>
              {instructor.bio && <p className="m-sub mt-1 text-ink-2">{instructor.bio}</p>}
            </div>
          </div>
          {certs.length > 0 && (
            <ul className="mt-3 space-y-1.5">
              {certs.map((c) => (
                <li key={c} className="m-sub flex items-center gap-2 text-ink-2">
                  <Icon name="certificate" size={16} className="shrink-0 text-ink-3" />
                  {c}
                </li>
              ))}
            </ul>
          )}
        </section>
      )}
    </>
  );
}
