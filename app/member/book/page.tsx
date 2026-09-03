import Link from "next/link";
import { Icon } from "@/components/member/icons";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import WeekStrip, { MonthGrid, type WeekDay, type MonthDay } from "@/components/member/week-strip";
import ClassCard from "@/components/member/class-card";
import { BookForm, ActionForm, CardAction, CardActionOutline } from "@/components/member/ui";
import { bookClass, cancelBooking, startCheckout, payAtDesk } from "../actions";
import { addDays, dayStart, fmtTime, zonedDateKey } from "@/lib/time";

export const dynamic = "force-dynamic";

/**
 * Booking, a day at a time inside a visible week.
 *
 * The day is still the unit — a thirty-day scroll is how you lose someone
 * looking for Thursday — but the week above it is what tells a member the
 * shape of what is on before they tap anything.
 */
export default async function Book({
  searchParams,
}: {
  searchParams: { d?: string; type?: string; instructor?: string; v?: string };
}) {
  const { ctx, supabase, studioName, logoUrl, preset, accent, settings , openOffers, memberName, avatarUrl} = await memberScreen();

  const offset = Number(searchParams.d ?? 0) || 0;
  const from = dayStart(new Date(), ctx.timeZone, offset);
  const to = addDays(from, 1);
  const now = Date.now();

  // The visible week: Monday of whichever week the selected day falls in.
  // Derived from the selected day rather than from today, so paging forward
  // three weeks does not leave the strip behind on this one.
  // Which weekday the selected day is, IN THE STUDIO'S ZONE. Reading
  // getUTCDay() off a zoned midnight is a different day for half the world:
  // Monday 00:00 in Prague is Sunday 23:00 UTC, and the strip would open on
  // the previous week for every studio east of London.
  const WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  const dow = Math.max(0, WEEKDAYS.indexOf(
    new Intl.DateTimeFormat("en-GB", { timeZone: ctx.timeZone, weekday: "short" }).format(from),
  ));
  const monthView = searchParams.v === "month";
  const weekFromOffset = offset - dow;

  // What the strip or the grid needs pips for. In week view that is seven days
  // from the selected week's Monday; in month view it is the whole calendar
  // block, leading and trailing days included, because those cells are drawn
  // and a drawn cell with no pip has to mean "nothing on", not "not asked".
  const monthStart = (() => {
    const parts = new Intl.DateTimeFormat("en-GB", {
      timeZone: ctx.timeZone, day: "numeric",
    }).formatToParts(from);
    return offset - (Number(parts.find((p) => p.type === "day")?.value ?? 1) - 1);
  })();
  const monthStartDow = (() => {
    const d = dayStart(new Date(), ctx.timeZone, monthStart);
    return Math.max(0, WEEKDAYS.indexOf(
      new Intl.DateTimeFormat("en-GB", { timeZone: ctx.timeZone, weekday: "short" }).format(d),
    ));
  })();
  const gridFromOffset = monthView ? monthStart - monthStartDow : weekFromOffset;
  const gridLength = monthView ? 42 : 7;

  const weekStartDay = dayStart(new Date(), ctx.timeZone, gridFromOffset);
  const weekEndDay = addDays(weekStartDay, gridLength);

  const [{ data: occurrences }, { data: week }, { data: types }, { data: instructors }, { data: mine }] =
    await Promise.all([
      supabase
        .from("class_occurrences")
        .select("id, name, starts_at, ends_at, capacity, booked_count, waitlist_count, class_type_id, instructor_id, instructors!instructor_id(display_name, avatar_url), class_types(image_url), rooms(name)")
        .gte("starts_at", from.toISOString())
        .lt("starts_at", to.toISOString())
        .order("starts_at"),
      // Just enough to put a dot under a day. Ids and times only — the strip
      // shows presence, not counts, so nothing else is worth fetching.
      supabase
        .from("class_occurrences")
        .select("id, starts_at")
        .gte("starts_at", weekStartDay.toISOString())
        .lt("starts_at", weekEndDay.toISOString()),
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
    const merged = { d: offset, v: monthView ? "month" : undefined,
                     type: typeFilter || undefined, instructor: instFilter || undefined, ...over };
    for (const [k, v] of Object.entries(merged)) {
      if (v !== undefined && v !== "" && !(k === "d" && v === 0)) p.set(k, String(v));
    }
    const q = p.toString();
    return q ? `/book?${q}` : "/book";
  };

  // Which days in the visible week have anything on.
  const busy = new Set((week ?? []).map((o: { starts_at: string }) => zonedDateKey(o.starts_at, ctx.timeZone)));
  const todayKey = zonedDateKey(new Date().toISOString(), ctx.timeZone);
  const selectedKey = zonedDateKey(from.toISOString(), ctx.timeZone);

  // Which month the selected day falls in, so a leading or trailing cell in
  // the grid can be dimmed rather than pretending to belong here.
  //
  // NUMBERS, not strings. An Intl field is formatted in the context of the
  // whole option set, not on its own: month:"numeric" alone gives "9", and the
  // same option beside a weekday and a day gives "09". Comparing the two as
  // text matched on no day of any month, so every cell in the grid rendered as
  // though it belonged to the next one.
  const selectedMonth = Number(new Intl.DateTimeFormat("en-GB", {
    timeZone: ctx.timeZone, month: "numeric",
  }).format(from));

  const days: MonthDay[] = Array.from({ length: gridLength }, (_, i) => {
    const dayOffset = gridFromOffset + i;
    const d = dayStart(new Date(), ctx.timeZone, dayOffset);
    const key = zonedDateKey(d.toISOString(), ctx.timeZone);
    const parts = new Intl.DateTimeFormat("en-GB", {
      timeZone: ctx.timeZone, weekday: "short", day: "numeric", month: "numeric",
    }).formatToParts(d);
    return {
      offset: dayOffset,
      dayOfMonth: Number(parts.find((p) => p.type === "day")?.value ?? 0),
      weekdayLabel: (parts.find((p) => p.type === "weekday")?.value ?? "").slice(0, 3),
      hasClasses: busy.has(key),
      isToday: key === todayKey,
      isSelected: key === selectedKey,
      isPast: key < todayKey,
      inMonth: Number(parts.find((p) => p.type === "month")?.value ?? 0) === selectedMonth,
    };
  });

  const monthLabel = new Intl.DateTimeFormat("en-GB", {
    timeZone: ctx.timeZone, month: "long", year: "numeric",
  }).format(from);

  const Pill = ({ href, active, children }: { href: string; active: boolean; children: React.ReactNode }) => (
    <Link href={href}
          aria-pressed={active}
          className="m-tap inline-flex shrink-0 items-center rounded-full px-3.5 text-[13px] font-semibold"
          style={active
            ? { background: "var(--accent-solid)", color: "var(--accent-on-solid)" }
            : { background: "var(--surface)", color: "var(--ink-2)",
                boxShadow: "0 1px 3px rgb(26 21 18 / 0.06)" }}>
      {children}
    </Link>
  );

  const minutes = (a: string, b: string | null) =>
    b ? Math.round((new Date(b).getTime() - new Date(a).getTime()) / 60000) : null;

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl} studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <section aria-label="Choose a day" className="mb-4">
        <div className="mb-2.5 flex items-center gap-2">
          <h2 className="m-head flex-1 truncate text-[17px] leading-6 text-ink">{monthLabel}</h2>

          {/* Week / Month. Both halves work: Week pages seven days at a time,
              Month draws the calendar block with the same pips. A segmented
              control with a dead half is exactly the decorative control this
              build refuses to draw. */}
          <div className="flex rounded-full p-0.5"
               style={{ background: "var(--surface)", boxShadow: "0 1px 3px rgb(26 21 18 / 0.06)" }}>
            {([["week", "Week"], ["month", "Month"]] as const).map(([v, label]) => {
              const on = monthView === (v === "month");
              return (
                <Link
                  key={v}
                  href={qs({ v: v === "week" ? undefined : v })}
                  aria-pressed={on}
                  className="rounded-full px-3 py-1.5 text-[12px] font-semibold leading-4"
                  style={on
                    ? { background: "var(--accent-solid)", color: "var(--accent-on-solid)" }
                    : { color: "var(--ink-2)" }}
                >
                  {label}
                </Link>
              );
            })}
          </div>

          <div className="flex items-center gap-1">
            <Link href={qs({ d: offset - (monthView ? 28 : 7) })} aria-label={monthView ? "Earlier" : "Previous week"}
                  className="flex h-8 w-8 items-center justify-center rounded-full bg-surface text-ink-2"
                  style={{ boxShadow: "0 1px 3px rgb(26 21 18 / 0.06)" }}>
              <Icon name="chevron-left" size={16} />
            </Link>
            <Link href={qs({ d: offset + (monthView ? 28 : 7) })} aria-label={monthView ? "Later" : "Next week"}
                  className="flex h-8 w-8 items-center justify-center rounded-full bg-surface text-ink-2"
                  style={{ boxShadow: "0 1px 3px rgb(26 21 18 / 0.06)" }}>
              <Icon name="chevron-right" size={16} />
            </Link>
          </div>
        </div>

        {monthView
          ? <MonthGrid days={days} hrefFor={(o) => qs({ d: o, v: undefined })} />
          : <WeekStrip days={days as WeekDay[]} hrefFor={(o) => qs({ d: o })} />}
      </section>

      <div className="m-hscroll -mx-4 mb-4 flex items-center gap-2 overflow-x-auto px-4 pb-1">
        <Pill href={qs({ type: undefined, instructor: undefined })} active={!typeFilter && !instFilter}>All</Pill>
        {(types ?? []).map((t) => (
          <Pill key={t.id} href={qs({ type: typeFilter === t.id ? undefined : t.id })} active={typeFilter === t.id}>
            {t.name}
          </Pill>
        ))}
        {(instructors ?? []).length > 0 && (
          <span className="m-micro flex shrink-0 items-center gap-2 pl-1 text-ink-2">
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
        <div className="m-card p-6 text-center">
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
        <ul className="space-y-3">
          {shown.map((o) => {
            const booking = byOcc.get(o.id);
            const booked = booking?.status === "booked";
            const waiting = booking?.status === "waitlisted";
            // A seat held while the member finishes paying. Deliberately not
            // rendered as booked: they have not paid, the sweep will take it
            // back, and telling them they are in the class would be a lie with
            // a fifteen-minute fuse on it.
            const holding = booking?.status === "pending_payment";
            const spaces = o.capacity - o.booked_count;
            const full = spaces <= 0;
            const past = new Date(o.starts_at).getTime() < now;
            const mins = minutes(o.starts_at, o.ends_at);

            const status = booked ? "Booked"
              : holding ? "Holding your spot"
              : waiting ? <>You&rsquo;re #<span className="num">{booking!.waitlist_position}</span> on the list</>
              : past ? "This one has started"
              : full ? "Fully booked"
              : <><span className="num">{spaces}</span> left</>;

            const action = past ? null
              : holding ? (
                  // Two ways to settle a held seat, because Decision 16 makes
                  // paying by card optional for the member as well as for the
                  // studio. Card is the filled button because they are already
                  // on their phone; the desk is a quiet link beside it.
                  <span className="flex flex-col items-end gap-1.5">
                    <BookForm action={startCheckout}>
                      <input type="hidden" name="kind" value="dropin" />
                      <input type="hidden" name="booking_id" value={booking!.id} />
                      <CardAction>Pay now</CardAction>
                    </BookForm>
                    <ActionForm action={payAtDesk}>
                      <input type="hidden" name="booking_id" value={booking!.id} />
                      <button className="m-meta text-ink-2 underline decoration-line-2 underline-offset-4">
                        Pay at the studio
                      </button>
                    </ActionForm>
                  </span>
                )
              : booked || waiting ? (
                  <ActionForm action={cancelBooking}>
                    <input type="hidden" name="booking_id" value={booking!.id} />
                    <CardActionOutline>{booked ? "Cancel" : "Leave list"}</CardActionOutline>
                  </ActionForm>
                )
              : full ? (
                  settings.waitlistEnabled ? (
                    <BookForm action={bookClass}>
                      <input type="hidden" name="occurrence_id" value={o.id} />
                      <CardActionOutline>Join waitlist</CardActionOutline>
                    </BookForm>
                  ) : null
                )
              : (
                  <BookForm action={bookClass}>
                    <input type="hidden" name="occurrence_id" value={o.id} />
                    <CardAction>Book</CardAction>
                  </BookForm>
                );

            return (
              <ClassCard
                key={o.id}
                href={`/class/${o.id}`}
                startLabel={fmtTime(o.starts_at, ctx.timeZone)}
                endLabel={o.ends_at ? fmtTime(o.ends_at, ctx.timeZone) : null}
                durationLabel={mins ? `${mins} min` : "—"}
                name={o.name}
                instructor={o.instructors?.display_name ?? null}
                room={o.rooms?.name ?? null}
                statusLabel={status}
                statusTone={booked ? "booked" : holding ? "holding" : full && !waiting ? "full" : "quiet"}
                action={action}
                booked={booked}
                dimmed={past}
              />
            );
          })}
        </ul>
      )}
    </MemberShell>
  );
}
