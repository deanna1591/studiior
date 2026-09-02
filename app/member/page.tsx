import Link from "next/link";
import { memberScreen, membershipState } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { ActionForm, BookForm, QuietButton } from "@/components/member/ui";
import IconChip from "@/components/member/icon-chip";
import Avatar from "@/components/member/avatar";
import { Icon } from "@/components/member/icons";
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
  const { ctx, supabase, studioName, logoUrl, preset, accent, settings , openOffers, memberName, avatarUrl} = await memberScreen();
  const now = Date.now();

  // The first of this month, in the studio's zone — not UTC, or a member in
  // Prague sees "classes this month" tick over at 2am on the wrong day.
  const monthStart = new Date(
    new Intl.DateTimeFormat("en-CA", {
      timeZone: ctx.timeZone, year: "numeric", month: "2-digit",
    }).format(new Date()) + "-01T00:00:00Z",
  );

  const [{ data: bookings }, { data: offers }, membership, { data: upcoming }, { count: thisMonth }] =
    await Promise.all([
    supabase
      .from("bookings")
      .select("id, status, waitlist_position, occurrence_id, class_occurrences(id, name, starts_at, ends_at, capacity, booked_count, class_type_id, instructors!instructor_id(display_name, avatar_url), class_types(image_url), rooms(name))")
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
      .select("id, name, starts_at, capacity, booked_count, instructors!instructor_id(display_name), class_types(image_url)")
      .gt("starts_at", new Date().toISOString())
      .order("starts_at")
      .limit(3),
    supabase
      .from("check_ins")
      .select("id", { count: "exact", head: true })
      .eq("member_id", ctx.memberId)
      .gte("checked_in_at", monthStart.toISOString()),
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

  // Their morning, not the server's. A member in Prague opening this at 7am
  // should not be told good evening because the box is in Virginia.
  const localHour = Number(
    new Intl.DateTimeFormat("en-GB", { timeZone: ctx.timeZone, hour: "numeric", hour12: false })
      .format(new Date()),
  );
  const greeting = localHour < 12 ? "Good morning" : localHour < 18 ? "Good afternoon" : "Good evening";

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl} studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      {/* The greeting. First person, their name, their part of the day — the one
          line in the app that speaks TO them rather than about their booking. */}
      {/* Text only. The greeting had the member's photograph beside it and the
          header has it too, a hundred pixels above — the same face twice on one
          screen reads as a duplication bug rather than as warmth. The header
          keeps it, because that is the one place it appears on every screen. */}
      <div className="mb-5">
        <p className="m-meta text-ink-3">{greeting}</p>
        <p className="text-[22px] font-semibold leading-7 text-ink">
          {memberName || "there"}
        </p>
      </div>

      {/* A live waitlist offer outranks everything: the seat is held for this
          member and only for as long as the offer lasts. §4.2. */}
      {(offers ?? []).map((o) => (
        <ActionForm key={o.id} action={respondToOffer} className="mb-4">
          <div className="rounded-[22px] p-5" style={{ background: "var(--lime-tint)" }}>
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
        <div className="mb-4 rounded-[22px] border-l-[3px] px-4 py-3.5"
             style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}>
          <p className="m-sub text-ink">
            Your last payment didn&rsquo;t go through. Pop into the studio or reply
            to our email and we&rsquo;ll sort it.
          </p>
        </div>
      )}

      {/* ---- the next class ---- */}
      {occ ? (
        <section className="m-card overflow-hidden">
          {/* The photograph runs to the card's edges and the type sits under it.
              Text over the image would need a scrim and would be unreadable
              against whatever the studio uploaded; the card is not the login
              screen and does not have a scrim to hide behind. */}
          {occ.class_types?.image_url && (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={occ.class_types.image_url} alt="" aria-hidden
                 className="h-40 w-full object-cover" />
          )}
          <div className="p-5">
          <p className="m-meta text-ink-3">
            {day(occ.starts_at)} · <span className="num">{fmtTime(occ.starts_at, ctx.timeZone)}</span>
          </p>
          <h1 className="m-title mt-1 text-ink">{occ.name}</h1>
          <div className="mt-3 space-y-2.5">
            {/* Decision 17: an unstaffed class is shown as a normal class. A
                member books a Reformer class because of the class; telling them
                nobody has agreed to teach it yet advertises a doubt they cannot
                act on and invites them not to book. The name appears the moment
                somebody is assigned. */}
            {occ.instructors?.display_name && (
              <p className="m-meta flex items-center gap-2.5 text-ink-2">
                {occ.instructors.avatar_url
                  ? <Avatar name={occ.instructors.display_name} url={occ.instructors.avatar_url} size={32} />
                  : <IconChip name="person" />}
                {occ.instructors.display_name}
              </p>
            )}
            {occ.rooms?.name && (
              <p className="m-meta flex items-center gap-2.5 text-ink-2">
                <IconChip name="door" />
                {occ.rooms.name}
              </p>
            )}
          </div>

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
          </div>
        </section>
      ) : (
        <section className="m-card p-5">
          <h1 className="m-title text-ink">Nothing booked</h1>
          <p className="m-sub mt-1 text-ink-2">Here&rsquo;s what&rsquo;s on next.</p>
          <ul className="mt-3 divide-y divide-line">
            {(upcoming ?? []).map((o) => (
              <li key={o.id}>
                <BookForm action={bookClass} className="flex items-center justify-between gap-3 py-2.5">
                  <span className="min-w-0">
                    <span className="m-body block truncate text-ink">{o.name}</span>
                    <span className="m-micro block text-ink-3">
                      {day(o.starts_at)} · <span className="num">{fmtTime(o.starts_at, ctx.timeZone)}</span>
                      {o.instructors?.display_name ? ` · ${o.instructors.display_name}` : ""}
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

      {/* ---- the three numbers that matter ----
          A row of tinted squares, each with its icon on a chip. Three and not
          two because "classes this month" is the one a member actually counts,
          and it was the only one the app knew and never showed. */}
      <div className="mt-4 grid grid-cols-3 gap-3">
        <div className="m-card p-4">
          <IconChip name="ticket" size={36} icon={18} />
          <p className="num m-stat mt-2.5 text-ink">
            {membership.live
              ? credits === null ? "∞" : credits
              : "—"}
          </p>
          <p className="m-meta text-ink-3">
            {membership.live && credits === null ? "Unlimited" : "Classes left"}
          </p>
        </div>
        <div className="m-card p-4">
          <IconChip name="flame" size={36} icon={18} />
          <p className="num m-stat mt-2.5 text-ink">{ctx.streak}</p>
          <p className="m-meta text-ink-3">{ctx.streak === 1 ? "Week streak" : "Week streak"}</p>
        </div>
        <div className="m-card p-4">
          <IconChip name="calendar" size={36} icon={18} />
          <p className="num m-stat mt-2.5 text-ink">{thisMonth ?? 0}</p>
          <p className="m-meta text-ink-3">This month</p>
        </div>
      </div>

      {mine.filter((b) => b.status === "booked" && b.id !== next?.id).length > 0 && (
        <section className="mt-6">
          <h2 className="m-sub mb-2.5 font-medium text-ink">Also booked</h2>
          <ul className="m-card divide-y divide-line overflow-hidden">
            {mine.filter((b) => b.status === "booked" && b.id !== next?.id).map((b) => (
              <li key={b.id} className="flex items-center justify-between gap-3 px-4 py-3.5">
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
