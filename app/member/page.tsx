import Link from "next/link";
import { memberScreen, membershipState } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { ActionForm, BookForm, PrimaryButton, QuietButton } from "@/components/member/ui";
import { bookClass, cancelBooking, respondToOffer } from "./actions";
import { fmtTime, fmtDayLong, relativeDayName, dayMonthParts } from "@/lib/time";

export const dynamic = "force-dynamic";

/**
 * Home. Not the schedule.
 *
 * This is the screen a member opens four times a week, usually to answer one
 * question: what am I doing next, and can I check in yet. So the next class is
 * the whole top of the screen, and inside the check-in window that card stops
 * describing the class and becomes the way in.
 */
export default async function MemberHome() {
  const { ctx, supabase, studioName, logoUrl, preset, accent, settings , openOffers} = await memberScreen();
  const now = Date.now();

  const [{ data: bookings }, { data: offers }, membership, { data: upcoming }] = await Promise.all([
    supabase
      .from("bookings")
      .select("id, status, waitlist_position, occurrence_id, class_occurrences(id, name, starts_at, ends_at, capacity, booked_count, instructors!instructor_id(display_name), rooms(name))")
      .eq("member_id", ctx.memberId)
      .in("status", ["booked", "waitlisted"])
      .order("booked_at"),
    supabase
      .from("waitlist_offers")
      .select("id, expires_at, occurrence_id, class_occurrences(name, starts_at)")
      .is("outcome", null)
      .gt("expires_at", new Date().toISOString()),
    membershipState(supabase, ctx.memberId),
    supabase
      .from("class_occurrences")
      .select("id, name, starts_at, capacity, booked_count, instructors!instructor_id(display_name)")
      .gt("starts_at", new Date().toISOString())
      .order("starts_at")
      .limit(3),
  ]);

  const mine = (bookings ?? [])
    .filter((b) => b.class_occurrences && new Date(b.class_occurrences.starts_at).getTime() > now - 3600e3)
    .sort((a, b) =>
      new Date(a.class_occurrences!.starts_at).getTime() -
      new Date(b.class_occurrences!.starts_at).getTime());

  const next = mine.find((b) => b.status === "booked");
  const occ = next?.class_occurrences ?? null;

  // The window is the studio's, read through studio_member_settings() — not a
  // 60 hard-coded here, because the setting exists so a studio can move it.
  const opensAt = occ ? new Date(occ.starts_at).getTime() - settings.checkinOpensBefore * 60e3 : 0;
  const closesAt = occ ? new Date(occ.ends_at ?? occ.starts_at).getTime() + settings.checkinClosesAfter * 60e3 : 0;
  const inWindow = !!occ && now >= opensAt && now <= closesAt;

  const canCancel =
    !!occ && new Date(occ.starts_at).getTime() - now > settings.cancellationCutoff * 60e3;

  const pastDue = membership.live?.status === "past_due";
  const credits = membership.live?.credits_remaining ?? null;

  const day = (iso: string) => relativeDayName(iso, ctx.timeZone) ?? fmtDayLong(iso, ctx.timeZone);

  return (
    <MemberShell openOffers={openOffers} studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      {/* A live waitlist offer outranks everything: the seat is held for this
          member and only for as long as the offer lasts. §4.2. */}
      {(offers ?? []).map((o) => (
        <ActionForm key={o.id} action={respondToOffer} className="mb-4">
          <div className="rounded-lg border border-line-2 bg-lime-tint p-4">
            <p className="m-body text-ink">
              A place has opened in{" "}
              <span className="font-medium">{o.class_occurrences?.name}</span>
              {o.class_occurrences && <> on {day(o.class_occurrences.starts_at)} at{" "}
                <span className="num">{fmtTime(o.class_occurrences.starts_at, ctx.timeZone)}</span></>}.
            </p>
            <p className="m-micro mt-1 text-ink-2">
              It is held for you until{" "}
              <span className="num">{fmtTime(o.expires_at, ctx.timeZone)}</span>.
            </p>
            <input type="hidden" name="offer_id" value={o.id} />
            <div className="mt-3 flex gap-2">
              <button name="accept" value="1"
                      style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
                      className="m-action flex-1 rounded-xl px-4 text-[16px] font-semibold">
                Take it
              </button>
              <button name="accept" value="0"
                      className="m-tap rounded-lg border border-line-2 bg-surface px-4 text-[14px] text-ink-2">
                No thanks
              </button>
            </div>
          </div>
        </ActionForm>
      ))}

      {pastDue && (
        <div className="mb-4 border-l-[3px] px-3 py-2.5"
             style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}>
          <p className="m-sub text-ink">
            Your last payment didn&rsquo;t go through. Pop into the studio or reply
            to our email and we&rsquo;ll sort it.
          </p>
        </div>
      )}

      {/* ---- the next class ---- */}
      {occ ? (
        <section className="rounded-xl border border-line bg-surface p-4">
          <p className="m-micro text-ink-3">
            {day(occ.starts_at)} · <span className="num">{fmtTime(occ.starts_at, ctx.timeZone)}</span>
          </p>
          <h1 className="m-display mt-1 text-ink">{occ.name}</h1>
          <p className="m-sub mt-1 text-ink-2">
            {occ.instructors?.display_name ?? "Instructor to be confirmed"}
            {occ.rooms?.name ? ` · ${occ.rooms.name}` : ""}
          </p>

          {inWindow ? (
            <>
              <Link
                href="/check-in"
                style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
                className="m-action mt-4 flex w-full items-center justify-center rounded-xl text-[16px] font-semibold"
              >
                Check in
              </Link>
              <p className="m-micro mt-2 text-center text-ink-3">
                Show the code at the desk.
              </p>
            </>
          ) : (
            <div className="mt-4">
              <p className="m-sub text-ink-2">You&rsquo;re booked in.</p>
              {/* A text link, not a button. Nothing needs doing on this screen
                  and a big bordered Cancel is the loudest thing on it, which
                  points a member at the one action they did not come for. */}
              {canCancel ? (
                <ActionForm action={cancelBooking} className="mt-2">
                  <input type="hidden" name="booking_id" value={next!.id} />
                  <button className="m-tap text-[14px] text-ink-3 underline decoration-line-2 underline-offset-4">
                    Cancel this booking
                  </button>
                </ActionForm>
              ) : (
                <p className="m-micro mt-2 text-ink-3">
                  Too late to cancel without using the class. Come anyway if you can.
                </p>
              )}
            </div>
          )}
        </section>
      ) : (
        <section className="rounded-xl border border-dashed border-line-2 p-4">
          <h1 className="m-display text-ink">Nothing booked</h1>
          <p className="m-sub mt-1 text-ink-2">Here&rsquo;s what&rsquo;s on next.</p>
          <ul className="mt-3 divide-y divide-line">
            {(upcoming ?? []).map((o) => (
              <li key={o.id}>
                <BookForm action={bookClass} className="flex items-center justify-between gap-3 py-2.5">
                  <span className="min-w-0">
                    <span className="m-body block truncate text-ink">{o.name}</span>
                    <span className="m-micro block text-ink-3">
                      {day(o.starts_at)} · <span className="num">{fmtTime(o.starts_at, ctx.timeZone)}</span>
                      {" · "}{o.instructors?.display_name ?? "TBC"}
                    </span>
                  </span>
                  <input type="hidden" name="occurrence_id" value={o.id} />
                  <QuietButton>Book</QuietButton>
                </BookForm>
              </li>
            ))}
            {(upcoming ?? []).length === 0 && (
              <li className="m-sub py-3 text-ink-3">
                No classes on the schedule yet. Your studio will add them soon.
              </li>
            )}
          </ul>
          <Link href="/book" className="m-sub mt-3 inline-block text-lime-text underline underline-offset-4">
            See the whole week
          </Link>
        </section>
      )}

      {/* ---- the two numbers that matter ---- */}
      <div className="mt-4 grid grid-cols-2 gap-3">
        <div className="rounded-lg border border-line bg-surface p-3">
          <p className="m-micro text-ink-3">
            {credits === null && membership.live ? "Membership" : "Classes left"}
          </p>
          <p className="mt-0.5 text-ink">
            {membership.live
              ? credits === null
                ? <span className="m-body">Unlimited</span>
                : <><span className="num text-[26px] leading-8">{credits}</span></>
              : <span className="m-body text-ink-2">None yet</span>}
          </p>
          {membership.live && (
            <p className="m-micro text-ink-3">{membership.live.membership_plans?.name}</p>
          )}
        </div>
        <div className="rounded-lg border border-line bg-surface p-3">
          <p className="m-micro text-ink-3">Weekly streak</p>
          <p className="mt-0.5 text-ink">
            <span className="num text-[26px] leading-8">{ctx.streak}</span>
            <span className="m-micro ml-1 text-ink-3">
              {ctx.streak === 1 ? "week" : "weeks"}
            </span>
          </p>
        </div>
      </div>

      {mine.filter((b) => b.status === "booked" && b.id !== next?.id).length > 0 && (
        <section className="mt-4">
          <h2 className="m-sub mb-2 font-medium text-ink">Also booked</h2>
          <ul className="divide-y divide-line rounded-xl border border-line bg-surface">
            {mine.filter((b) => b.status === "booked" && b.id !== next?.id).map((b) => (
              <li key={b.id} className="flex items-center justify-between gap-3 px-3 py-2.5">
                <span className="min-w-0">
                  <span className="m-body block truncate text-ink">{b.class_occurrences!.name}</span>
                  <span className="m-micro block text-ink-3">
                    {day(b.class_occurrences!.starts_at)} ·{" "}
                    <span className="num">{fmtTime(b.class_occurrences!.starts_at, ctx.timeZone)}</span>
                  </span>
                </span>
                <Link href="/book" className="m-micro shrink-0 text-lime-text underline underline-offset-4">
                  Manage
                </Link>
              </li>
            ))}
          </ul>
        </section>
      )}

      {mine.filter((b) => b.status === "waitlisted").map((b) => (
        <p key={b.id} className="m-sub mt-4 rounded-lg border border-line bg-amber-tint px-3 py-2.5 text-ink">
          You&rsquo;re <span className="num">#{b.waitlist_position}</span> on the list for{" "}
          {b.class_occurrences?.name}
          {b.class_occurrences && <> on {day(b.class_occurrences.starts_at)}</>}.
          We&rsquo;ll tell you if a place opens.
        </p>
      ))}
    </MemberShell>
  );
}
