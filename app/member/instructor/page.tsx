import Link from "next/link";
import { instructorScreen, studioToday, shiftDate } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";
import { ConfirmWeek, AcceptCover } from "./actions-ui";
import PayCheckIn from "./pay-checkin";

export const dynamic = "force-dynamic";

type Klass = {
  occurrence_id: string; name: string; local_date: string;
  local_start: string; local_end: string; room_name: string | null;
  capacity: number; booked_count: number; waitlist_count: number;
  status: string; cancellation_reason: string | null; cancellation_cause: string | null;
  flex: boolean; minimum_bookings: number | null; committed: boolean;
  tier: string | null; confirmed: boolean; cover_requested: boolean;
  checked_in: boolean; checkin_open: boolean;
};

/**
 * MY WEEK — the thing an instructor opens.
 *
 * Time, class, room, and how many are booked. Two states beyond that decide
 * whether they are working at all, and both are drawn plainly:
 *
 *  - a FLEX class still waiting on its deadline reads as still waiting, with
 *    how many it needs. Decision 21 keeps this from members on purpose —
 *    telling somebody a class might not run is telling them not to bother
 *    booking it — but the person who would have to turn up and teach it has
 *    every reason to know.
 *  - one that WILL NOT RUN says so, with the reason, rather than quietly
 *    vanishing from the list.
 */
export default async function MyWeek({
  searchParams,
}: { searchParams: { w?: string } }) {
  const { ctx, supabase } = await instructorScreen();
  const today = studioToday(ctx.timezone);
  const offset = Number(searchParams.w) || 0;
  const from = shiftDate(today, offset * 7);
  const to = shiftDate(from, 13);

  const [week, cover, rosters, anns, coverNeeded] = await Promise.all([
    supabase.rpc("instructor_week", {
      p_instructor_id: ctx.instructor_id, p_from: from, p_to: to,
    }),
    supabase.from("cover_requests")
      .select("occurrence_id, status")
      .eq("instructor_id", ctx.instructor_id).eq("status", "pending"),
    // Decision 25. A roster sent and not yet confirmed — their own rows only,
    // under roster_conf_own_read. Empty for a studio that never publishes.
    supabase.from("roster_confirmations")
      .select("month, classes_at_notify")
      .eq("instructor_id", ctx.instructor_id)
      .not("notified_at", "is", null).is("confirmed_at", null)
      .gte("month", today.slice(0, 7) + "-01")
      .order("month").limit(1),
    // Decision 27: instructor-audience announcements for the portal.
    supabase.rpc("instructor_announcements", { p_studio_id: ctx.studio_id }),
    // Auto-accept cover (156): urgent covers this instructor can take right now,
    // no approval round. Empty unless the studio runs auto-accept.
    supabase.rpc("cover_available_to", { p_instructor_id: ctx.instructor_id }),
  ]);
  const coverClasses = ((coverNeeded.data as unknown as { classes: {
    id: string; time: string; date: string; class_name: string; room: string | null; booked: number; capacity: number;
  }[] } | null)?.classes) ?? [];
  const coverWhen = (iso: string, t: string) =>
    new Intl.DateTimeFormat("en-GB", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" })
      .format(new Date(`${iso}T12:00:00Z`)) + ` · ${t}`;
  const announcements = (anns.data ?? []) as unknown as
    { id: string; title: string; body: string }[];
  const roster = (rosters.data ?? [])[0] ?? null;
  const rosterLabel = roster
    ? new Intl.DateTimeFormat("en-GB", { month: "long", timeZone: "UTC" })
        .format(new Date(`${roster.month}T00:00:00Z`))
    : null;

  const w = week.data as { state: string; classes: Klass[]; empty_hint: string } | null;
  const classes = w?.classes ?? [];
  const byDay = new Map<string, Klass[]>();
  for (const c of classes) {
    if (!byDay.has(c.local_date)) byDay.set(c.local_date, []);
    byDay.get(c.local_date)!.push(c);
  }
  const dayLabel = (iso: string) =>
    new Intl.DateTimeFormat("en-GB", {
      timeZone: "UTC", weekday: "long", day: "numeric", month: "short",
    }).format(new Date(`${iso}T00:00:00Z`));

  const unconfirmed = classes.filter(
    (c) => c.status === "scheduled" && !c.confirmed && !c.cover_requested);

  return (
    <InstructorShell ctx={ctx} title={offset === 0 ? "My week" : "Later"}>
      {announcements.length > 0 && (
        <section className="mb-4 space-y-3">
          {announcements.map((a) => (
            <article key={a.id} className="m-card p-4">
              <p className="m-name text-ink">{a.title}</p>
              <p className="m-sub mt-1 whitespace-pre-line text-ink-2">{a.body}</p>
            </article>
          ))}
        </section>
      )}
      {week.error && (
        <div className="m-card mb-4 border-l-[3px] px-3 py-2.5"
             style={{ borderLeftColor: "var(--coral)" }} role="alert">
          <p className="text-[13px] leading-[19px] text-ink">
            Your week could not be read — this is not an empty week.
          </p>
          <p className="num mt-1 text-[11px] leading-4 text-ink-2">{week.error.message}</p>
        </div>
      )}

      {/* Auto-accept cover (156): a class needs cover soon and you can take it
          right now, first come. Loud, above the roster nudge. */}
      {coverClasses.length > 0 && (
        <section className="mb-4">
          <div className="m-card px-4 py-3.5" style={{ boxShadow: "0 0 0 1.5px var(--lime-text)" }}>
            <p className="text-[15px] font-semibold leading-[22px] text-ink">Cover needed now</p>
            <p className="m-sub mt-0.5 text-ink-3">
              A class needs cover soon — whoever takes it first gets it, no waiting on the studio.
            </p>
            <ul className="mt-3 space-y-2">
              {coverClasses.map((c) => (
                <li key={c.id} className="rounded-xl border border-line px-3 py-2.5">
                  <div className="flex items-baseline gap-2">
                    <span className="num shrink-0 text-[15px] font-semibold text-ink">{c.time}</span>
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-[14px] text-ink">{c.class_name}</span>
                      <span className="m-sub block text-ink-3">
                        {coverWhen(c.date, c.time)}{c.room ? ` · ${c.room}` : ""} · <span className="num">{c.booked}/{c.capacity}</span> booked
                      </span>
                    </span>
                  </div>
                  <AcceptCover occurrenceId={c.id} />
                </li>
              ))}
            </ul>
          </div>
        </section>
      )}

      {/* Decision 25: the month is the agreement, and it is asked for here
          because this is the screen they open. The screen behind the link
          lists the classes and takes the press. */}
      {roster && rosterLabel && (
        <Link href={`/instructor/month?m=${roster.month.slice(0, 7)}`}
              className="m-card mb-4 block px-4 py-3.5">
          <p className="text-[15px] leading-[22px] text-ink">
            Your {rosterLabel} roster is ready —{" "}
            <span className="num font-semibold">{roster.classes_at_notify}</span>{" "}
            {roster.classes_at_notify === 1 ? "class" : "classes"}.
          </p>
          <p className="m-sub mt-0.5 text-[color:var(--accent-text)] underline underline-offset-4">
            Confirm the month, or flag any you cannot do
          </p>
        </Link>
      )}

      {/* Migration 067's one press for the whole week, folded in rather than
          living at a separate address. A class somebody has asked cover for is
          ANSWERED, not unconfirmed, and is not counted here. */}
      {unconfirmed.length > 0 && (
        <ConfirmWeek instructorId={ctx.instructor_id} count={unconfirmed.length} weekStart={from} />
      )}

      {classes.length === 0 ? (
        <div className="m-card px-4 py-6">
          <p className="text-[15px] leading-6 text-ink">Nothing on.</p>
          <p className="m-sub mt-1 text-ink-2">{w?.empty_hint}</p>
          <Link href="/instructor/shifts"
                className="mt-3 inline-block text-[13px] font-medium text-[color:var(--accent-text)] underline underline-offset-4">
            See what is going
          </Link>
        </div>
      ) : (
        <div className="space-y-5">
          {[...byDay.entries()].map(([day, list]) => (
            <section key={day}>
              <h2 className="m-sub mb-2 text-ink-3">
                {day === today ? "Today" : dayLabel(day)}
              </h2>
              <ul className="space-y-2">
                {list.map((c) => <ClassRow key={c.occurrence_id} c={c} />)}
              </ul>
            </section>
          ))}
        </div>
      )}

      <div className="mt-6 flex items-center justify-between">
        <Link href={`/instructor?w=${offset - 1}`}
              className="m-sub text-ink-2 underline underline-offset-4">← Earlier</Link>
        {offset !== 0 && (
          <Link href="/instructor" className="m-sub text-ink-2 underline underline-offset-4">
            This week
          </Link>
        )}
        <Link href={`/instructor?w=${offset + 1}`}
              className="m-sub text-ink-2 underline underline-offset-4">Later →</Link>
      </div>
    </InstructorShell>
  );
}

function ClassRow({ c }: { c: Klass }) {
  const off = c.status === "cancelled";
  // Decision 21: flex, past nothing yet, still waiting on its minimum.
  const waiting = !off && c.flex && !c.committed;
  const short = waiting ? (c.minimum_bookings ?? 0) - c.booked_count : 0;

  return (
    <li className={`m-card px-3 py-2.5 ${off ? "opacity-70" : ""}`}>
      <Link href={off ? "#" : `/instructor/roster/${c.occurrence_id}`}
            className={off ? "pointer-events-none block" : "block"}>
        <div className="flex items-baseline gap-3">
          <span className="num shrink-0 text-[16px] font-semibold leading-5 text-ink">
            {c.local_start}
          </span>
          <span className="min-w-0 flex-1">
            <span className={`block truncate text-[15px] leading-5 text-ink ${off ? "line-through" : ""}`}>
              {c.name}
            </span>
            <span className="m-sub block text-ink-3">
              {c.room_name ?? "No room"} · {c.local_start}–{c.local_end}
            </span>
          </span>
          <span className="num shrink-0 text-[13px] leading-5 text-ink-2">
            {c.booked_count}/{c.capacity}
          </span>
        </div>

        {off && (
          <p className="mt-1.5 text-[12px] leading-[17px] text-ink">
            <span className="font-medium">Not running.</span>{" "}
            {c.cancellation_cause === "unmet_minimum"
              ? "It did not reach its minimum."
              : c.cancellation_reason || "The studio cancelled it."}
          </p>
        )}
        {waiting && (
          <p className="mt-1.5 text-[12px] leading-[17px] text-ink-2">
            Still waiting on numbers —{" "}
            {short > 0
              ? <>needs <span className="num">{short}</span> more to run.</>
              : <>it has enough and is not confirmed yet.</>}
          </p>
        )}
        {c.cover_requested && (
          <p className="mt-1.5 text-[12px] leading-[17px] text-ink-2">
            You have asked for cover. The studio decides — nothing is released
            until they do.
          </p>
        )}
        {!off && !c.cover_requested && c.confirmed && (
          <p className="mt-1.5 text-[12px] leading-[17px] text-ink-3">Confirmed.</p>
        )}
      </Link>
      {/* Decision 28: check in for pay. A ran, committed class you have not
          checked into, while the window is open. Cancelled/flex-waiting ones
          have no check-in — you cannot check in to a class that did not run. */}
      {!off && !waiting && c.committed && !c.checked_in && c.checkin_open && (
        <PayCheckIn occurrenceId={c.occurrence_id} />
      )}
      {!off && c.checked_in && (
        <p className="mt-1.5 text-[12px] font-medium" style={{ color: "var(--lime-text)" }}>Checked in for pay ✓</p>
      )}
    </li>
  );
}
