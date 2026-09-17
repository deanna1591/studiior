import Link from "next/link";
import { instructorScreen, studioToday, shiftDate } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";
import { AcceptCover } from "./actions-ui";
import { notifLabel, relTime, type NotifItem } from "@/lib/instructor-notify";

export const dynamic = "force-dynamic";

type Klass = {
  occurrence_id: string; name: string; local_date: string;
  local_start: string; local_end: string; room_name: string | null;
  capacity: number; booked_count: number; status: string;
  confirmed: boolean; cover_requested: boolean;
};

/**
 * HOME — the thing the portal opens on, and it answers "what needs me today"
 * before it offers a menu. Same principle as the studio dashboard: it should
 * feel like it already knew.
 *
 *  - the next class, and enough of it to walk in prepared
 *  - anything still waiting on THEM — a week to confirm, availability the studio
 *    has queried, a cover that can be taken now
 *  - the two or three notifications that matter
 *  - and, when there is genuinely nothing, it says so rather than padding
 */
export default async function InstructorHome() {
  const { ctx, supabase } = await instructorScreen();
  const today = studioToday(ctx.timezone);

  const [week, rosters, changes, coverNeeded, notifData, anns] = await Promise.all([
    supabase.rpc("instructor_week", {
      p_instructor_id: ctx.instructor_id, p_from: today, p_to: shiftDate(today, 13),
    }),
    supabase.from("roster_confirmations")
      .select("month, classes_at_notify")
      .eq("instructor_id", ctx.instructor_id)
      .not("notified_at", "is", null).is("confirmed_at", null)
      .gte("month", today.slice(0, 7) + "-01")
      .order("month").limit(1),
    supabase.from("availability_submissions")
      .select("period_start")
      .eq("instructor_id", ctx.instructor_id).eq("status", "changes_requested")
      .order("period_start", { ascending: false }).limit(1),
    supabase.rpc("cover_available_to", { p_instructor_id: ctx.instructor_id }),
    supabase.rpc("instructor_notifications", { p_instructor_id: ctx.instructor_id, p_limit: 6 }),
    supabase.rpc("instructor_announcements", { p_studio_id: ctx.studio_id }),
  ]);

  const w = week.data as { classes?: Klass[] } | null;
  const classes = (w?.classes ?? [])
    .filter((c) => c.status === "scheduled")
    .sort((a, b) =>
      (a.local_date + a.local_start).localeCompare(b.local_date + b.local_start));
  const next = classes[0] ?? null;
  const unconfirmed = classes.filter((c) => !c.confirmed && !c.cover_requested).length;

  const roster = (rosters.data ?? [])[0] ?? null;
  const rosterLabel = roster
    ? new Intl.DateTimeFormat("en-GB", { month: "long", timeZone: "UTC" })
        .format(new Date(`${roster.month}T00:00:00Z`))
    : null;
  const availChanges = (changes.data ?? []).length > 0;

  const coverClasses = ((coverNeeded.data as unknown as { classes?: {
    id: string; time: string; date: string; class_name: string; room: string | null; booked: number; capacity: number;
  }[] } | null)?.classes) ?? [];
  const notifs = ((notifData.data as { items?: NotifItem[] } | null)?.items ?? []).slice(0, 3);
  const announcements = (anns.data ?? []) as unknown as { id: string; title: string; body: string }[];

  const nextDay = (iso: string) => iso === today ? "Today"
    : new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", weekday: "long", day: "numeric", month: "short" })
        .format(new Date(`${iso}T00:00:00Z`));
  const coverWhen = (iso: string, t: string) =>
    new Intl.DateTimeFormat("en-GB", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" })
      .format(new Date(`${iso}T12:00:00Z`)) + ` · ${t}`;

  // "Needs you" — the things still waiting on the instructor.
  const waiting: { key: string; label: string; href: string }[] = [];
  if (unconfirmed > 0)
    waiting.push({ key: "confirm", href: "/instructor/schedule",
      label: `Confirm ${unconfirmed} ${unconfirmed === 1 ? "class" : "classes"} this fortnight` });
  if (roster && rosterLabel)
    waiting.push({ key: "roster", href: "/instructor/month",
      label: `Your ${rosterLabel} roster is ready to confirm` });
  if (availChanges)
    waiting.push({ key: "avail", href: "/instructor/availability",
      label: "The studio asked for changes to your availability" });

  const quiet = !next && waiting.length === 0 && coverClasses.length === 0;

  return (
    <InstructorShell ctx={ctx}>
      {/* NEXT CLASS */}
      {next ? (
        <Link href={`/instructor/roster/${next.occurrence_id}`} className="m-card block px-4 py-4">
          <p className="m-sub text-ink-3">Next class</p>
          <p className="mt-1 text-[19px] font-semibold leading-6 text-ink">{next.name}</p>
          <p className="mt-1 text-[14px] leading-5 text-ink-2">
            <span className="num">{nextDay(next.local_date)} · {next.local_start}–{next.local_end}</span>
            {next.room_name ? ` · ${next.room_name}` : ""}
          </p>
          <p className="m-sub mt-0.5 text-ink-3">
            <span className="num">{next.booked_count}</span> of{" "}
            <span className="num">{next.capacity}</span> booked · tap for the roster
          </p>
        </Link>
      ) : (
        <div className="m-card px-4 py-4">
          <p className="m-sub text-ink-3">Next class</p>
          <p className="mt-1 text-[15px] leading-6 text-ink">Nothing in the next fortnight.</p>
          <Link href="/instructor/schedule"
                className="m-sub mt-1 inline-block underline underline-offset-4"
                style={{ color: "var(--accent-text)" }}>See your whole schedule</Link>
        </div>
      )}

      {/* COVER NEEDED NOW — urgent, first come. */}
      {coverClasses.length > 0 && (
        <section className="mt-4">
          <div className="m-card px-4 py-3.5" style={{ boxShadow: "0 0 0 1.5px var(--lime-text)" }}>
            <p className="text-[15px] font-semibold leading-[22px] text-ink">Cover needed now</p>
            <p className="m-sub mt-0.5 text-ink-3">
              Whoever takes it first gets it — no waiting on the studio.
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

      {/* NEEDS YOU */}
      {waiting.length > 0 && (
        <section className="mt-5">
          <h2 className="m-sub mb-2 text-ink-3">Waiting on you</h2>
          <ul className="space-y-2">
            {waiting.map((it) => (
              <li key={it.key}>
                <Link href={it.href} className="m-card flex items-center gap-3 px-4 py-3.5">
                  <span className="mt-0.5 h-2 w-2 shrink-0 rounded-full" style={{ background: "var(--lime-text)" }} />
                  <span className="flex-1 text-[15px] leading-5 text-ink">{it.label}</span>
                  <span className="shrink-0 text-ink-3">›</span>
                </Link>
              </li>
            ))}
          </ul>
        </section>
      )}

      {/* RECENT NOTIFICATIONS */}
      {notifs.length > 0 && (
        <section className="mt-5">
          <div className="mb-2 flex items-baseline justify-between">
            <h2 className="m-sub text-ink-3">Recent</h2>
            <Link href="/instructor/notifications"
                  className="m-sub underline underline-offset-4" style={{ color: "var(--accent-text)" }}>
              All notifications
            </Link>
          </div>
          <ul className="space-y-2">
            {notifs.map((n) => (
              <li key={n.id} className="m-card flex items-start gap-3 px-3.5 py-3">
                <span className="mt-1.5 h-2 w-2 shrink-0 rounded-full"
                      style={{ background: n.read ? "var(--line-2)" : "var(--lime-text)" }} />
                <span className="min-w-0 flex-1">
                  <span className={`block text-[14px] leading-5 ${n.read ? "text-ink-2" : "text-ink"}`}>
                    {notifLabel(n.template_key).title}
                  </span>
                  <span className="m-sub block text-ink-3">{relTime(n.created_at)}</span>
                </span>
              </li>
            ))}
          </ul>
        </section>
      )}

      {/* ANNOUNCEMENTS */}
      {announcements.length > 0 && (
        <section className="mt-5 space-y-3">
          {announcements.map((a) => (
            <article key={a.id} className="m-card p-4">
              <p className="m-name text-ink">{a.title}</p>
              <p className="m-sub mt-1 whitespace-pre-line text-ink-2">{a.body}</p>
            </article>
          ))}
        </section>
      )}

      {quiet && (
        <p className="m-sub mt-5 text-ink-3">Nothing needs you today.</p>
      )}
    </InstructorShell>
  );
}
