import Link from "next/link";
import { memberScreen, membershipState } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { ActionForm, BookForm, QuietButton } from "@/components/member/ui";
import IconChip from "@/components/member/icon-chip";
import Avatar from "@/components/member/avatar";
import { Icon } from "@/components/member/icons";
import { bookClass, cancelBooking, respondToOffer } from "./actions";
import { fmtTime, fmtDayLong, relativeDayName, dayMonthParts } from "@/lib/time";
import { accentRamp, accentGradient, neutralAccent } from "@/lib/theme";

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

  // The hero's fallback when a studio has uploaded no class photograph — the
  // accent's own gradient, derived, never a stock image and never Studiior's
  // lime. accentGradient moves its second stop AWAY from the text colour, so
  // the white type over it can only gain contrast.
  const [g1, g2] = accentGradient(accentRamp(accent ?? neutralAccent(preset), preset));
  // The scrim sits over this as well as over a photograph, so white type is
  // measured against the composite, not against the accent — a light accent
  // like lime is 1.3 with white on it bare and 7.0 under the scrim.
  const heroFallback = `linear-gradient(140deg, ${g1} 0%, ${g2} 100%)`;

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl} studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      {/* The greeting. First person, their name, their part of the day — the one
          line in the app that speaks TO them rather than about their booking. */}
      {/* Text only. The greeting had the member's photograph beside it and the
          header has it too, a hundred pixels above — the same face twice on one
          screen reads as a duplication bug rather than as warmth. The header
          keeps it, because that is the one place it appears on every screen. */}
      {/* --ink-3 measures 4.19 on the page wash and is only safe inside a white
          card. On the wash the floor is --ink-2 (6.66 worst across 8 accents
          and 4 presets). */}
      <div className="mb-4">
        <p className="m-eyebrow text-ink-2">{greeting}</p>
        <p className="m-head text-[23px] leading-7 text-ink">{memberName || "there"}</p>
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
        <section className="m-hero" style={!occ.class_types?.image_url ? { background: heroFallback } : undefined}>
          {occ.class_types?.image_url && (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={occ.class_types.image_url} alt="" aria-hidden
                 className="absolute inset-0 h-full w-full object-cover" />
          )}
          <span aria-hidden className="m-hero-scrim" />

          <div className="relative flex h-full flex-col justify-between p-4">
            <span className="m-hero-tag self-start rounded-full px-2.5 py-1 text-[11px] font-semibold leading-4">
              {day(occ.starts_at)} · <span className="num">{fmtTime(occ.starts_at, ctx.timeZone)}</span>
            </span>

            <div className="flex items-end justify-between gap-3">
              <div className="min-w-0">
                <h1 className="m-head truncate text-[19px] leading-6 text-white">{occ.name}</h1>
                <p className="mt-0.5 truncate text-[12px] leading-4 text-white/90">
                  {/* Decision 17: an unstaffed class reads as a normal class.
                      Telling a member nobody has agreed to teach it advertises
                      a doubt they cannot act on. */}
                  {[occ.instructors?.display_name, occ.rooms?.name].filter(Boolean).join(" · ")
                    || "You\u2019re booked in"}
                </p>
              </div>

              {/* The check-in button lives INSIDE the hero, and only inside the
                  window. Outside it there is nothing to press: the card is
                  telling you about a class, not asking for anything. */}
              {inWindow && (
                <Link href="/check-in"
                      className="m-tap flex shrink-0 items-center rounded-full px-4 text-[13px] font-bold"
                      // The accent's own measured pair. A white pill with
                      // --ink on it measured 1.09 on Bold, whose ink is nearly
                      // white; the pair is derived together and cannot come
                      // apart like that.
                      style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
                  Check in
                </Link>
              )}
            </div>
          </div>
        </section>
      ) : null}

      {occ && !inWindow && (
        <div className="mt-2.5 px-1">
          {canCancel ? (
            <ActionForm action={cancelBooking}>
              <input type="hidden" name="booking_id" value={next!.id} />
              {/* A text link, not a button. Nothing needs doing on this screen
                  and a filled Cancel would be the loudest thing on it. */}
              <button className="m-tap text-[12.5px] text-ink-2 underline decoration-line-2 underline-offset-4">
                Cancel this booking
              </button>
            </ActionForm>
          ) : (
            <p className="m-subtle text-ink-2">
              Too late to cancel without using the class. Come anyway if you can.
            </p>
          )}
        </div>
      )}

      {/* Nothing booked. The hero is still a hero — the next class ON THE
          SCHEDULE, with the button that books it. An empty state that only
          says "nothing booked" makes the member go and find the schedule
          themselves, which is the one thing this screen exists to save them. */}
      {!occ && (() => {
        const o = (upcoming ?? [])[0];
        if (!o) {
          return (
            <section className="m-card p-5">
              <h1 className="m-title text-ink">Nothing booked</h1>
              <p className="m-sub mt-1 text-ink-2">
                No classes on the schedule yet. Your studio will add them soon.
              </p>
            </section>
          );
        }
        return (
          <section className="m-hero" style={!o.class_types?.image_url ? { background: heroFallback } : undefined}>
            {o.class_types?.image_url && (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={o.class_types.image_url} alt="" aria-hidden
                   className="absolute inset-0 h-full w-full object-cover" />
            )}
            <span aria-hidden className="m-hero-scrim" />
            <div className="relative flex h-full flex-col justify-between p-4">
              <span className="m-hero-tag self-start rounded-full px-2.5 py-1 text-[11px] font-semibold leading-4">
                Next up · {day(o.starts_at)}
              </span>
              <div className="flex items-end justify-between gap-3">
                <div className="min-w-0">
                  <h1 className="m-head truncate text-[19px] leading-6 text-white">{o.name}</h1>
                  <p className="mt-0.5 truncate text-[12px] leading-4 text-white/90">
                    <span className="num">{fmtTime(o.starts_at, ctx.timeZone)}</span>
                    {o.instructors?.display_name ? ` \u00b7 ${o.instructors.display_name}` : ""}
                  </p>
                </div>
                <BookForm action={bookClass} className="shrink-0">
                  <input type="hidden" name="occurrence_id" value={o.id} />
                  <button className="m-tap flex items-center rounded-full px-4 text-[13px] font-bold"
                          style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
                    Book
                  </button>
                </BookForm>
              </div>
            </div>
          </section>
        );
      })()}

      {/* ---- coming up ----
          A row that scrolls sideways, each card opening the class detail. It is
          here because the hero answers "what is next" and nothing answered
          "what else". Every card is a link to a real screen. */}
      {(upcoming ?? []).length > 0 && (
        <section className="mt-5">
          <div className="mb-2.5 flex items-baseline justify-between">
            <h2 className="m-eyebrow font-semibold text-ink">Coming up</h2>
            <Link href="/book" className="m-subtle font-medium" style={{ color: "var(--lime-text)" }}>
              See all
            </Link>
          </div>
          <ul className="m-hscroll -mx-4 flex gap-3 overflow-x-auto px-4 pb-1">
            {(upcoming ?? []).map((o) => (
              <li key={o.id} className="w-[124px] shrink-0">
                <Link href={`/class/${o.id}`} className="block">
                  <span
                    className="mb-2 block h-[88px] w-full overflow-hidden rounded-2xl"
                    style={!o.class_types?.image_url ? { background: heroFallback } : undefined}
                  >
                    {o.class_types?.image_url && (
                      // eslint-disable-next-line @next/next/no-img-element
                      <img src={o.class_types.image_url} alt="" aria-hidden
                           className="h-full w-full object-cover" />
                    )}
                  </span>
                  <span className="m-name block truncate text-ink">{o.name}</span>
                  <span className="m-subtle block truncate text-ink-2">
                    {day(o.starts_at)} · <span className="num">{fmtTime(o.starts_at, ctx.timeZone)}</span>
                  </span>
                </Link>
              </li>
            ))}
          </ul>
        </section>
      )}

      {/* ---- the three numbers that matter ----
          A row of tinted squares, each with its icon on a chip. Three and not
          two because "classes this month" is the one a member actually counts,
          and it was the only one the app knew and never showed. */}
      <div className="mt-4 grid grid-cols-3 gap-2.5">
        {([
          ["ticket",   membership.live ? (credits === null ? "\u221e" : String(credits)) : "\u2014",
                       membership.live && credits === null ? "Unlimited" : "Classes left"],
          ["flame",    String(ctx.streak), "Week streak"],
          ["calendar", String(thisMonth ?? 0), "This month"],
        ] as const).map(([icon, value, label]) => (
          <div key={label} className="m-card p-3">
            <span className="m-icon-sq" aria-hidden><Icon name={icon} size={14} /></span>
            <p className="num mt-2 text-[21px] font-bold leading-6 text-ink">{value}</p>
            {/* Inside a white card, so --ink-3 is back on the table: it is 4.59
                on --surface. On the page wash it would be 4.19 and fail. */}
            <p className="m-subtle text-ink-3">{label}</p>
          </div>
        ))}
      </div>

      {mine.filter((b) => b.status === "booked" && b.id !== next?.id).length > 0 && (
        <section className="mt-5">
          <h2 className="m-eyebrow mb-2.5 font-semibold text-ink">Also booked</h2>
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
