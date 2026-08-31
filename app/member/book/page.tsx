import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { BookForm, ActionForm, QuietButton } from "@/components/member/ui";
import { bookClass, cancelBooking } from "../actions";
import { addDays, dayStart, fmtTime, fmtDayLong, relativeDayName } from "@/lib/time";

export const dynamic = "force-dynamic";

/**
 * Booking, one day at a time.
 *
 * A thirty-day scroll is how you lose someone looking for Thursday. The day is
 * the unit a member thinks in, so the day is the unit the screen moves in, and
 * the filters narrow what is already a short list rather than a long one.
 *
 * A class you are in does not get a tick somewhere on the row — the row itself
 * reads differently, because "am I in this one" is the question being asked
 * and it should be answerable without reading.
 */
export default async function Book({
  searchParams,
}: {
  searchParams: { d?: string; type?: string; instructor?: string };
}) {
  const { ctx, supabase, studioName, logoUrl, settings } = await memberScreen();

  const offset = Number(searchParams.d ?? 0) || 0;
  const from = dayStart(new Date(), ctx.timeZone, offset);
  const to = addDays(from, 1);
  const now = Date.now();

  const [{ data: occurrences }, { data: types }, { data: instructors }, { data: mine }] =
    await Promise.all([
      supabase
        .from("class_occurrences")
        .select("id, name, starts_at, capacity, booked_count, waitlist_count, class_type_id, instructor_id, instructors!instructor_id(display_name), rooms(name)")
        .gte("starts_at", from.toISOString())
        .lt("starts_at", to.toISOString())
        .order("starts_at"),
      supabase.from("class_types").select("id, name").eq("status", "active").order("name"),
      supabase.from("instructors").select("id, display_name").eq("status", "active").order("display_name"),
      supabase.from("bookings")
        .select("id, status, occurrence_id, waitlist_position")
        .eq("member_id", ctx.memberId)
        .in("status", ["booked", "waitlisted"]),
    ]);

  const byOcc = new Map((mine ?? []).map((b) => [b.occurrence_id, b]));

  const typeFilter = searchParams.type ?? "";
  const instFilter = searchParams.instructor ?? "";
  const shown = (occurrences ?? []).filter(
    (o) => (!typeFilter || o.class_type_id === typeFilter) &&
           (!instFilter || o.instructor_id === instFilter),
  );

  const qs = (over: Record<string, string | number | undefined>) => {
    const p = new URLSearchParams();
    const merged = { d: offset, type: typeFilter || undefined, instructor: instFilter || undefined, ...over };
    for (const [k, v] of Object.entries(merged)) {
      if (v !== undefined && v !== "" && !(k === "d" && v === 0)) p.set(k, String(v));
    }
    const q = p.toString();
    return q ? `/book?${q}` : "/book";
  };

  const label = relativeDayName(from.toISOString(), ctx.timeZone)
    ?? fmtDayLong(from.toISOString(), ctx.timeZone);

  const Pill = ({ href, active, children }: { href: string; active: boolean; children: React.ReactNode }) => (
    <Link href={href}
          className={`m-tap inline-flex shrink-0 items-center rounded-full border px-3.5 text-[13px] ${
            active ? "border-lime-text bg-lime-tint font-medium text-lime-text"
                   : "border-line-2 bg-surface text-ink-2"}`}>
      {children}
    </Link>
  );

  return (
    <MemberShell studioName={studioName} logoUrl={logoUrl}>
      {/* Day navigation with targets you can hit walking. */}
      <div className="mb-3 flex items-center justify-between gap-2">
        <Link href={qs({ d: offset - 1 })} aria-label="Previous day"
              className="m-tap flex w-12 items-center justify-center rounded-lg border border-line-2 bg-surface text-ink-2">‹</Link>
        <div className="min-w-0 text-center">
          <p className="m-body truncate font-medium text-ink">{label}</p>
          {offset !== 0 && (
            <Link href={qs({ d: 0 })} className="m-micro text-lime-text underline underline-offset-4">
              Back to today
            </Link>
          )}
        </div>
        <Link href={qs({ d: offset + 1 })} aria-label="Next day"
              className="m-tap flex w-12 items-center justify-center rounded-lg border border-line-2 bg-surface text-ink-2">›</Link>
      </div>

      {/* Two kinds of filter in one strip. Without the divider "Barre" and
          "Bo Fictitious" are the same-looking pill and a member cannot tell
          whether they are choosing a class or a teacher. */}
      <div className="m-hscroll -mx-4 mb-4 flex items-center gap-2 overflow-x-auto px-4 pb-1">
        <Pill href={qs({ type: undefined, instructor: undefined })} active={!typeFilter && !instFilter}>All</Pill>
        {(types ?? []).map((t) => (
          <Pill key={t.id} href={qs({ type: typeFilter === t.id ? undefined : t.id })} active={typeFilter === t.id}>
            {t.name}
          </Pill>
        ))}
        {(instructors ?? []).length > 0 && (
          <span className="m-micro flex shrink-0 items-center gap-2 pl-1 text-ink-3">
            <span className="h-5 w-px bg-line-2" aria-hidden />
            Taught by
          </span>
        )}
        {(instructors ?? []).map((i) => (
          <Pill key={i.id} href={qs({ instructor: instFilter === i.id ? undefined : i.id })} active={instFilter === i.id}>
            {i.display_name}
          </Pill>
        ))}
      </div>

      {shown.length === 0 ? (
        <div className="rounded-xl border border-dashed border-line-2 p-5 text-center">
          <p className="m-body text-ink">
            {typeFilter || instFilter ? "Nothing matching on this day." : "No classes on this day."}
          </p>
          <p className="m-sub mt-1 text-ink-2">
            {typeFilter || instFilter
              ? <Link href={qs({ type: undefined, instructor: undefined })} className="text-lime-text underline underline-offset-4">Show everything</Link>
              : <Link href={qs({ d: offset + 1 })} className="text-lime-text underline underline-offset-4">Try tomorrow</Link>}
          </p>
        </div>
      ) : (
        <ul className="space-y-2">
          {shown.map((o) => {
            const booking = byOcc.get(o.id);
            const booked = booking?.status === "booked";
            const waiting = booking?.status === "waitlisted";
            const spaces = o.capacity - o.booked_count;
            const full = spaces <= 0;
            const past = new Date(o.starts_at).getTime() < now;

            return (
              <li key={o.id}
                  className={`rounded-xl border p-3 ${
                    booked ? "border-lime-text bg-lime-tint"
                    : waiting ? "border-amber bg-amber-tint"
                    : "border-line bg-surface"}`}>
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <p className="m-micro text-ink-3">
                      <span className="num">{fmtTime(o.starts_at, ctx.timeZone)}</span>
                      {o.rooms?.name ? ` · ${o.rooms.name}` : ""}
                    </p>
                    <p className={`m-body font-medium ${past ? "text-ink-3" : "text-ink"}`}>{o.name}</p>
                    <p className="m-micro text-ink-2">
                      {o.instructors?.display_name ?? "Instructor to be confirmed"}
                    </p>
                  </div>
                  <p className="m-micro shrink-0 text-right text-ink-3">
                    {full
                      ? <>Full{(o.waitlist_count ?? 0) > 0 && <> · <span className="num">{o.waitlist_count}</span> waiting</>}</>
                      : <><span className="num">{spaces}</span> {spaces === 1 ? "space" : "spaces"}</>}
                  </p>
                </div>

                <div className="mt-3">
                  {booked ? (
                    <ActionForm action={cancelBooking}>
                      <p className="m-sub mb-2 font-medium text-ink">You&rsquo;re going.</p>
                      <input type="hidden" name="booking_id" value={booking!.id} />
                      <QuietButton>Cancel</QuietButton>
                    </ActionForm>
                  ) : waiting ? (
                    <ActionForm action={cancelBooking}>
                      <p className="m-sub mb-2 text-ink">
                        You&rsquo;re <span className="num font-medium">#{booking!.waitlist_position}</span> on the list.
                      </p>
                      <input type="hidden" name="booking_id" value={booking!.id} />
                      <QuietButton>Leave the list</QuietButton>
                    </ActionForm>
                  ) : past ? (
                    <p className="m-sub text-ink-3">This one has started.</p>
                  ) : (
                    <BookForm action={bookClass}>
                      <input type="hidden" name="occurrence_id" value={o.id} />
                      {/* Book is compact and right-aligned; joining a waitlist
                          is not, because it has something to explain. A
                          full-width lime button on every row makes each one
                          180px tall — two classes to a screen on a day with
                          six — and turns a list into a column of lime. */}
                      {full && settings.waitlistEnabled ? (
                        <>
                          <button className="m-action w-full rounded-lg bg-lime text-[15px] font-medium text-ink">
                            Join the waitlist — you&rsquo;d be #{(o.waitlist_count ?? 0) + 1}
                          </button>
                          <p className="m-micro mt-1.5 text-center text-ink-3">
                            No class is used unless a place opens and you take it.
                          </p>
                        </>
                      ) : (
                        <div className="flex justify-end">
                          <button
                            disabled={full}
                            className="m-tap min-w-[104px] rounded-lg bg-lime px-5 text-[15px] font-medium text-ink disabled:bg-line disabled:text-ink-3"
                          >
                            {full ? "Full" : "Book"}
                          </button>
                        </div>
                      )}
                    </BookForm>
                  )}
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </MemberShell>
  );
}
