import Link from "next/link";
import { instructorScreen, studioToday, shiftDate } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";
import { ConfirmWeek, ConfirmSeriesAssignments, ConfirmOrDecline } from "../actions-ui";
import PayCheckIn from "../pay-checkin";

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

type Pending = {
  occurrence_id: string; name: string; local_date: string;
  local_start: string; local_end: string; room_name: string | null;
  capacity: number; booked_count: number;
};

/**
 * MY SCHEDULE — everything the instructor is holding, and its state, in ONE
 * place. Confirmed classes AND claims still waiting on the studio, so a claim
 * they made never reads as lost: it sits here marked pending until staff
 * approve it (an approved claim then becomes an ordinary assigned class).
 *
 * Two states beyond the ordinary decide whether they are working at all:
 *  - a FLEX class still waiting on its deadline reads as still waiting, with how
 *    many it needs (Decision 21 keeps this from members; the person who would
 *    have to turn up has every reason to know).
 *  - one that WILL NOT RUN says so, with the reason, rather than vanishing.
 */
export default async function MySchedule({
  searchParams,
}: { searchParams: { w?: string } }) {
  const { ctx, supabase } = await instructorScreen();
  const today = studioToday(ctx.timezone);
  const offset = Number(searchParams.w) || 0;
  const from = shiftDate(today, offset * 7);
  const to = shiftDate(from, 13);

  const [week, pendingData, reqData] = await Promise.all([
    supabase.rpc("instructor_week", {
      p_instructor_id: ctx.instructor_id, p_from: from, p_to: to,
    }),
    // Claims awaiting approval — not on the calendar yet (instructor_id stays
    // null until staff approve), so instructor_week cannot see them.
    supabase.rpc("instructor_pending_claims", { p_instructor_id: ctx.instructor_id }),
    // Decision 38: classes the studio assigned that need confirming.
    supabase.rpc("instructor_assignment_requests", { p_instructor_id: ctx.instructor_id }),
  ]);

  const w = week.data as { state: string; classes: Klass[]; empty_hint: string } | null;
  const classes = w?.classes ?? [];
  const allPending = (pendingData.data ?? []) as unknown as Pending[];
  // Pending claims that fall inside this two-week view sit in the day list; the
  // rest are summarised so the instructor still knows they are outstanding.
  const pending = allPending.filter((p) => p.local_date >= from && p.local_date <= to);
  const pendingOutside = allPending.length - pending.length;

  type Day = { klass?: Klass; pending?: Pending };
  const byDay = new Map<string, Day[]>();
  for (const c of classes) {
    if (!byDay.has(c.local_date)) byDay.set(c.local_date, []);
    byDay.get(c.local_date)!.push({ klass: c });
  }
  for (const p of pending) {
    if (!byDay.has(p.local_date)) byDay.set(p.local_date, []);
    byDay.get(p.local_date)!.push({ pending: p });
  }
  const days = [...byDay.keys()].sort();

  const dayLabel = (iso: string) =>
    new Intl.DateTimeFormat("en-GB", {
      timeZone: "UTC", weekday: "long", day: "numeric", month: "short",
    }).format(new Date(`${iso}T00:00:00Z`));

  const unconfirmed = classes.filter(
    (c) => c.status === "scheduled" && !c.confirmed && !c.cover_requested);

  // Decision 38: assigned classes needing confirmation, grouped by series.
  type Req = {
    occurrence_id: string; name: string; local_date: string; local_start: string;
    room_name: string | null; series_id: string | null; series_name: string | null;
  };
  const requests = (reqData.data ?? []) as unknown as Req[];
  const reqGroups = new Map<string, { key: string; seriesId: string | null; name: string; items: Req[] }>();
  for (const r of requests) {
    const key = r.series_id ?? r.occurrence_id;
    if (!reqGroups.has(key)) {
      reqGroups.set(key, { key, seriesId: r.series_id, name: r.series_name ?? r.name, items: [] });
    }
    reqGroups.get(key)!.items.push(r);
  }
  const reqDayLabel = (iso: string) =>
    new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", weekday: "short", day: "numeric", month: "short" })
      .format(new Date(`${iso}T00:00:00Z`));

  const nothing = days.length === 0;

  return (
    <InstructorShell ctx={ctx} title={offset === 0 ? "My schedule" : "Later"}>
      {week.error && (
        <div className="m-card mb-4 border-l-[3px] px-3 py-2.5"
             style={{ borderLeftColor: "var(--coral)" }} role="alert">
          <p className="text-[13px] leading-[19px] text-ink">
            Your schedule could not be read — this is not an empty week.
          </p>
          <p className="num mt-1 text-[11px] leading-4 text-ink-2">{week.error.message}</p>
        </div>
      )}

      {/* Decision 38: classes the studio ASSIGNED that are waiting on your
          confirmation. Grouped by series: Confirm all, or per class Confirm /
          Can't make it (which raises a cover request — Decision 18, the class
          stays yours until someone covers it). */}
      {requests.length > 0 && (
        <div className="m-card mb-4 px-4 py-3.5">
          <p className="text-[15px] leading-[22px] text-ink">
            <span className="num font-semibold">{requests.length}</span>{" "}
            {requests.length === 1 ? "class needs" : "classes need"} your confirmation.
          </p>
          <p className="m-sub mt-0.5 text-ink-3">
            The studio put {requests.length === 1 ? "it" : "these"} on your schedule. Confirm, or hand back.
          </p>
          {[...reqGroups.values()].map((g) => (
            <div key={g.key} className="mt-3 border-t border-line pt-3">
              <p className="text-[13px] font-medium text-ink">{g.name}</p>
              <ul className="mt-1.5 space-y-2">
                {g.items.map((r) => (
                  <li key={r.occurrence_id} className="flex flex-col gap-1.5">
                    <span className="text-[12px] leading-[17px] text-ink-2">
                      {reqDayLabel(r.local_date)} · {r.local_start}
                      {r.room_name ? ` · ${r.room_name}` : ""}
                    </span>
                    <ConfirmOrDecline occurrenceId={r.occurrence_id} />
                  </li>
                ))}
              </ul>
              {g.seriesId && g.items.length > 1 && (
                <div className="mt-2.5">
                  <ConfirmSeriesAssignments
                    seriesId={g.seriesId} count={g.items.length}
                    label={g.items.length === 1 ? "class" : "classes"} />
                </div>
              )}
            </div>
          ))}
        </div>
      )}

      {/* Migration 067's one press for the whole week. A class somebody has asked
          cover for is ANSWERED, not unconfirmed, and is not counted here. */}
      {unconfirmed.length > 0 && (
        <ConfirmWeek instructorId={ctx.instructor_id} count={unconfirmed.length} weekStart={from} />
      )}

      {pendingOutside > 0 && (
        <p className="m-sub mb-3 text-ink-3">
          <span className="num">{pendingOutside}</span> more{" "}
          {pendingOutside === 1 ? "claim is" : "claims are"} waiting on the studio,
          later than this fortnight.
        </p>
      )}

      {nothing ? (
        <div className="m-card px-4 py-6">
          <p className="text-[15px] leading-6 text-ink">Nothing on this fortnight.</p>
          <p className="m-sub mt-1 text-ink-2">{w?.empty_hint}</p>
          <Link href="/instructor/shifts"
                className="mt-3 inline-block text-[13px] font-medium underline underline-offset-4"
                style={{ color: "var(--accent-text)" }}>
            See what is going
          </Link>
        </div>
      ) : (
        <div className="space-y-5">
          <a href={`/instructor/ics/month/${from.slice(0, 7)}`}
             className="m-press block text-[13px] leading-[18px] text-ink-2 underline underline-offset-4">
            Add this month to your calendar
          </a>
          {days.map((day) => (
            <section key={day}>
              <h2 className="m-sub mb-2 text-ink-3">
                {day === today ? "Today" : dayLabel(day)}
              </h2>
              <ul className="space-y-2">
                {(byDay.get(day) ?? [])
                  .sort((a, b) =>
                    (a.klass?.local_start ?? a.pending!.local_start).localeCompare(
                      b.klass?.local_start ?? b.pending!.local_start))
                  .map((row, i) =>
                    row.klass
                      ? <ClassRow key={row.klass.occurrence_id} c={row.klass} />
                      : <PendingRow key={`p-${row.pending!.occurrence_id}-${i}`} p={row.pending!} />
                  )}
              </ul>
            </section>
          ))}
        </div>
      )}

      <div className="mt-6 flex items-center justify-between">
        <Link href={`/instructor/schedule?w=${offset - 1}`}
              className="m-sub text-ink-2 underline underline-offset-4">← Earlier</Link>
        {offset !== 0 && (
          <Link href="/instructor/schedule" className="m-sub text-ink-2 underline underline-offset-4">
            This fortnight
          </Link>
        )}
        <Link href={`/instructor/schedule?w=${offset + 1}`}
              className="m-sub text-ink-2 underline underline-offset-4">Later →</Link>
      </div>
    </InstructorShell>
  );
}

function PendingRow({ p }: { p: Pending }) {
  return (
    <li className="m-card px-3 py-2.5" style={{ boxShadow: "inset 0 0 0 1.5px var(--accent-chip)" }}>
      <div className="flex items-baseline gap-3">
        <span className="num shrink-0 text-[16px] font-semibold leading-5 text-ink">{p.local_start}</span>
        <span className="min-w-0 flex-1">
          <span className="block truncate text-[15px] leading-5 text-ink">{p.name}</span>
          <span className="m-sub block text-ink-3">
            {p.room_name ?? "No room"} · {p.local_start}–{p.local_end}
          </span>
        </span>
        <span className="shrink-0 rounded-full px-2.5 py-0.5 text-[11px] font-semibold"
              style={{ background: "var(--accent-chip)", color: "var(--lime-text)" }}>Pending</span>
      </div>
      <p className="mt-1.5 text-[12px] leading-[17px] text-ink-2">
        You have asked to take this. It is not yours until the studio approves —
        they will tell you either way.
      </p>
    </li>
  );
}

function ClassRow({ c }: { c: Klass }) {
  const off = c.status === "cancelled";
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
          checked into, while the window is open. */}
      {!off && !waiting && c.committed && !c.checked_in && c.checkin_open && (
        <PayCheckIn occurrenceId={c.occurrence_id} />
      )}
      {!off && c.checked_in && (
        <p className="mt-1.5 text-[12px] font-medium" style={{ color: "var(--lime-text)" }}>Checked in for pay ✓</p>
      )}
      {!off && (
        <a href={`/instructor/ics/class/${c.occurrence_id}`}
           className="m-press mt-1.5 inline-block text-[12px] leading-[17px] text-ink-3 underline underline-offset-4">
          Add to calendar
        </a>
      )}
    </li>
  );
}
