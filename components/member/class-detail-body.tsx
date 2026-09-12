import { focalPoint } from "@/lib/focal";
import Avatar from "@/components/member/avatar";
import { Icon } from "@/components/member/icons";
import IconChip from "@/components/member/icon-chip";
import { BookForm, ActionForm, PrimaryButton, CardActionOutline } from "@/components/member/ui";
import { bookClass, cancelBooking } from "@/app/member/actions";
import { fmtTime, fmtDayLong } from "@/lib/time";

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
  occ, type, booking, timeZone, waitlistEnabled,
}: {
  occ: DetailOccurrence;
  type: DetailType;
  booking: DetailBooking;
  timeZone: string;
  waitlistEnabled: boolean;
}) {
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
    <>
      {type?.image_url && (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={type.image_url} alt="" aria-hidden
             className="mb-4 h-52 w-full rounded-[22px] object-cover"
             style={{ objectPosition: focalPoint(type.image_focus_x, type.image_focus_y) }} />
      )}

      <h1 className="m-title text-ink">{occ.name}</h1>

      <div className="mt-3 flex flex-wrap items-center gap-x-2 gap-y-1">
        <span className="num text-[16px] font-semibold text-ink">
          {fmtTime(occ.starts_at, timeZone)}
          {occ.ends_at && <> – {fmtTime(occ.ends_at, timeZone)}</>}
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
          waitlistEnabled ? (
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
    </>
  );
}
