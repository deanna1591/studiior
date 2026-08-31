import Link from "next/link";
import { notFound } from "next/navigation";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import Avatar from "@/components/member/avatar";
import { Icon } from "@/components/member/icons";
import { BookForm, ActionForm, PrimaryButton, CardActionOutline } from "@/components/member/ui";
import { bookClass, cancelBooking } from "../../actions";
import { fmtTime, fmtDayLong } from "@/lib/time";

export const dynamic = "force-dynamic";

/**
 * One class, in full.
 *
 * The list can only carry a name, and "Reformer Flow" and "Reformer Beginners"
 * are the same four syllables to somebody who has never been. The description
 * and the instructor's bio have been in the schema since migration 001 and the
 * staff forms have been capturing them all along; nothing has ever shown them
 * to the person deciding whether to turn up.
 *
 * A member may read instructors and class_types already — both have a
 * *_member_read policy from migration 001, which I checked against a real
 * member session rather than assuming migration 025 had left them staff-only.
 */
export default async function ClassDetail({ params }: { params: { id: string } }) {
  const { ctx, supabase, studioName, logoUrl, preset, accent, settings , openOffers} = await memberScreen();

  const { data: occ } = await supabase
    .from("class_occurrences")
    .select("id, name, starts_at, ends_at, capacity, booked_count, waitlist_count, status, class_type_id, instructor_id, rooms(name), instructors!instructor_id(display_name, bio, avatar_url, certifications)")
    .eq("id", params.id)
    .maybeSingle();

  // Not found and not-allowed-to-see are the same answer here on purpose: a
  // 404 that distinguished them would confirm a class exists at a studio the
  // member has nothing to do with.
  if (!occ) notFound();

  const [{ data: type }, { data: booking }] = await Promise.all([
    occ.class_type_id
      ? supabase.from("class_types").select("name, description").eq("id", occ.class_type_id).maybeSingle()
      : Promise.resolve({ data: null }),
    supabase.from("bookings")
      .select("id, status, waitlist_position")
      .eq("member_id", ctx.memberId)
      .eq("occurrence_id", params.id)
      .in("status", ["booked", "waitlisted"])
      .maybeSingle(),
  ]);

  const booked = booking?.status === "booked";
  const waiting = booking?.status === "waitlisted";
  const spaces = occ.capacity - occ.booked_count;
  const full = spaces <= 0;
  const past = new Date(occ.starts_at).getTime() < Date.now();
  const mins = occ.ends_at
    ? Math.round((new Date(occ.ends_at).getTime() - new Date(occ.starts_at).getTime()) / 60000)
    : null;

  const instructor = occ.instructors;
  const certs = Array.isArray(instructor?.certifications)
    ? (instructor!.certifications as string[]).filter(Boolean)
    : [];

  return (
    <MemberShell openOffers={openOffers} studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href="/book" className="m-sub mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> All classes
      </Link>

      {/* .m-title, not .m-display: the class name is the studio's words, and
          .m-display uppercases. "MAT PILATES" is a typographic decision about
          someone else's content — the same call as not shouting the studio's
          own name on the login screen. */}
      <h1 className="m-title text-ink">{occ.name}</h1>

      <div className="mt-3 flex flex-wrap items-center gap-x-2 gap-y-1">
        <span className="num text-[16px] font-semibold text-ink">
          {fmtTime(occ.starts_at, ctx.timeZone)}
          {occ.ends_at && <> – {fmtTime(occ.ends_at, ctx.timeZone)}</>}
        </span>
        {mins && (
          <span className="rounded-full bg-paper px-2 py-0.5 text-[11px] leading-4 text-ink-2">
            <span className="num">{mins}</span> mins
          </span>
        )}
      </div>
      <p className="m-sub mt-1 text-ink-2">{fmtDayLong(occ.starts_at, ctx.timeZone)}</p>
      {occ.rooms?.name && (
        <p className="m-sub mt-2 flex items-center gap-2 text-ink-2">
          <Icon name="door" size={16} className="text-ink-3" /> {occ.rooms.name}
        </p>
      )}

      {/* The decision, before the reading. Someone who already knows this class
          should not have to scroll past a bio to book it. */}
      <div className="m-card mt-4 p-4">
        <p className="m-sub mb-3 text-ink-2">
          {past ? "This class has already started."
            : booked ? "You're booked in."
            : waiting ? <>You&rsquo;re #<span className="num">{booking!.waitlist_position}</span> on the waitlist.</>
            : full ? <>Fully booked{(occ.waitlist_count ?? 0) > 0 && <> · <span className="num">{occ.waitlist_count}</span> waiting</>}</>
            : <><span className="num font-medium text-ink">{spaces}</span> {spaces === 1 ? "place" : "places"} left</>}
        </p>

        {past ? null : booked || waiting ? (
          <ActionForm action={cancelBooking}>
            <input type="hidden" name="booking_id" value={booking!.id} />
            <CardActionOutline>{booked ? "Cancel booking" : "Leave the list"}</CardActionOutline>
          </ActionForm>
        ) : full ? (
          settings.waitlistEnabled ? (
            <BookForm action={bookClass}>
              <input type="hidden" name="occurrence_id" value={occ.id} />
              <PrimaryButton>Join the waitlist</PrimaryButton>
              <p className="m-micro mt-1.5 text-center text-ink-3">
                No class is used unless a place opens and you take it.
              </p>
            </BookForm>
          ) : (
            <p className="m-sub text-ink-3">This class is full and has no waitlist.</p>
          )
        ) : (
          <BookForm action={bookClass}>
            <input type="hidden" name="occurrence_id" value={occ.id} />
            <PrimaryButton>Book this class</PrimaryButton>
          </BookForm>
        )}
      </div>

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
    </MemberShell>
  );
}
