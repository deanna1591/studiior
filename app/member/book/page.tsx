import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import WeekStrip, { type WeekDay } from "@/components/member/week-strip";
import ClassCard from "@/components/member/class-card";
import { BookForm, ActionForm, CardAction, CardActionOutline } from "@/components/member/ui";
import { bookClass, cancelBooking } from "../actions";
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
  searchParams: { d?: string; type?: string; instructor?: string };
}) {
  const { ctx, supabase, studioName, logoUrl, preset, accent, settings , openOffers} = await memberScreen();

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
  const weekFromOffset = offset - dow;
  const weekStartDay = dayStart(new Date(), ctx.timeZone, weekFromOffset);
  const weekEndDay = addDays(weekStartDay, 7);

  const [{ data: occurrences }, { data: week }, { data: types }, { data: instructors }, { data: mine }] =
    await Promise.all([
      supabase
        .from("class_occurrences")
        .select("id, name, starts_at, ends_at, capacity, booked_count, waitlist_count, class_type_id, instructor_id, instructors!instructor_id(display_name), rooms(name)")
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
    const merged = { d: offset, type: typeFilter || undefined, instructor: instFilter || undefined, ...over };
    for (const [k, v] of Object.entries(merged)) {
      if (v !== undefined && v !== "" && !(k === "d" && v === 0)) p.set(k, String(v));
    }
    const q = p.toString();
    return q ? `/book?${q}` : "/book";
  };

  // Which days in the visible week have anything on.
  const busy = new Set((week ?? []).map((o) => zonedDateKey(o.starts_at, ctx.timeZone)));
  const todayKey = zonedDateKey(new Date().toISOString(), ctx.timeZone);
  const selectedKey = zonedDateKey(from.toISOString(), ctx.timeZone);

  const days: WeekDay[] = Array.from({ length: 7 }, (_, i) => {
    const dayOffset = weekFromOffset + i;
    const d = dayStart(new Date(), ctx.timeZone, dayOffset);
    const key = zonedDateKey(d.toISOString(), ctx.timeZone);
    const parts = new Intl.DateTimeFormat("en-GB", {
      timeZone: ctx.timeZone, weekday: "short", day: "numeric",
    }).formatToParts(d);
    return {
      offset: dayOffset,
      dayOfMonth: Number(parts.find((p) => p.type === "day")?.value ?? 0),
      weekdayLabel: (parts.find((p) => p.type === "weekday")?.value ?? "").slice(0, 3),
      hasClasses: busy.has(key),
      isToday: key === todayKey,
      isSelected: key === selectedKey,
      isPast: key < todayKey,
    };
  });

  const monthLabel = new Intl.DateTimeFormat("en-GB", {
    timeZone: ctx.timeZone, month: "long", year: "numeric",
  }).format(from);

  const Pill = ({ href, active, children }: { href: string; active: boolean; children: React.ReactNode }) => (
    <Link href={href}
          className={`m-tap inline-flex shrink-0 items-center rounded-full border px-3.5 text-[13px] ${
            active ? "border-lime-text bg-lime-tint font-medium text-lime-text"
                   : "border-line-2 bg-surface text-ink-2"}`}>
      {children}
    </Link>
  );

  const minutes = (a: string, b: string | null) =>
    b ? Math.round((new Date(b).getTime() - new Date(a).getTime()) / 60000) : null;

  return (
    <MemberShell openOffers={openOffers} studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <WeekStrip
        days={days}
        monthLabel={monthLabel}
        hrefFor={(o) => qs({ d: o })}
        prevHref={qs({ d: offset - 7 })}
        nextHref={qs({ d: offset + 7 })}
      />

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
            const spaces = o.capacity - o.booked_count;
            const full = spaces <= 0;
            const past = new Date(o.starts_at).getTime() < now;
            const mins = minutes(o.starts_at, o.ends_at);

            const timeRange = (
              <>
                {fmtTime(o.starts_at, ctx.timeZone)}
                {o.ends_at && <> – {fmtTime(o.ends_at, ctx.timeZone)}</>}
              </>
            );

            const status = booked ? "Booked"
              : waiting ? <>You&rsquo;re #<span className="num">{booking!.waitlist_position}</span> on the list</>
              : past ? "This one has started"
              : full ? "Fully booked"
              : <><span className="num">{spaces}</span> left</>;

            const action = past ? null
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
                timeRange={timeRange}
                durationLabel={mins ? <><span className="num">{mins}</span> mins</> : "—"}
                name={o.name}
                instructor={o.instructors?.display_name ?? "Instructor to be confirmed"}
                room={o.rooms?.name ?? null}
                statusLabel={status}
                statusTone={booked ? "booked" : full && !waiting ? "full" : "quiet"}
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
