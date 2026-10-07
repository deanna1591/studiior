import Link from "next/link";
import { instructorScreen, studioToday, shiftDate } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";
import AnnounceStrip from "@/components/member/announce-strip";
import { AcceptCover } from "./actions-ui";
import ClassTag from "@/components/instructor/class-tag";
import { notifLabel, relTime, type NotifItem } from "@/lib/instructor-notify";
import { notificationHref } from "@/lib/notification-href";

export const dynamic = "force-dynamic";

type Klass = {
  occurrence_id: string; name: string; local_date: string;
  local_start: string; local_end: string; room_name: string | null;
  capacity: number; booked_count: number; status: string;
  confirmed: boolean; cover_requested: boolean;
  tier: string | null; flex: boolean; committed: boolean; flex_deadline_short: string | null;
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

  // The month being collected for availability, and this month's due day.
  const [ty, tm] = today.split("-").map(Number);
  const nextMonthISO = new Date(Date.UTC(ty, tm, 1)).toISOString().slice(0, 10);

  const [week, rosters, changes, coverNeeded, notifData, anns, settings, availCovered, nextTeach, availPub] = await Promise.all([
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
    supabase.from("studio_settings").select("availability_due_day, cover_escalation_hours")
      .eq("studio_id", ctx.studio_id).maybeSingle(),
    // Decision 46 amendment: the ONE definition of "on file" — a submission OR a
    // covering standing pattern the studio entered. 'none' means genuinely due.
    supabase.rpc("instructor_month_covered", {
      p_instructor_id: ctx.instructor_id, p_period_start: nextMonthISO }),
    // Decision 58: when this fortnight is empty, open on the next week they teach.
    supabase.rpc("instructor_next_teaching_week", { p_instructor_id: ctx.instructor_id }),
    // Decision 46 amendment: a published next month is never asked for (an actual
    // schedule_publications row, not month_published which is true publication-off).
    supabase.from("schedule_publications").select("id")
      .eq("studio_id", ctx.studio_id).eq("month", nextMonthISO).maybeSingle(),
  ]);

  const w = week.data as { classes?: Klass[]; confirmations_on?: boolean } | null;
  const confirmationsOn = w?.confirmations_on ?? false;
  const classes = (w?.classes ?? [])
    .filter((c) => c.status === "scheduled")
    .sort((a, b) =>
      (a.local_date + a.local_start).localeCompare(b.local_date + b.local_start));
  let next = classes[0] ?? null;
  // Decision 58: nothing in the next fortnight — name and show the next week
  // this instructor actually teaches, rather than "nothing coming up".
  let nextWeekLabel: string | null = null;
  if (!next) {
    const nw = nextTeach.data as string | null;
    if (nw) {
      const { data: fw } = await supabase.rpc("instructor_week", {
        p_instructor_id: ctx.instructor_id, p_from: nw, p_to: shiftDate(nw, 6),
      });
      const fclasses = ((fw as { classes?: Klass[] } | null)?.classes ?? [])
        .filter((c) => c.status === "scheduled")
        .sort((a, b) => (a.local_date + a.local_start).localeCompare(b.local_date + b.local_start));
      next = fclasses[0] ?? null;
      if (next) {
        nextWeekLabel = new Intl.DateTimeFormat("en-GB", {
          timeZone: "UTC", day: "numeric", month: "short",
        }).format(new Date(`${nw}T00:00:00Z`));
      }
    }
  }
  // Decision 58: no confirm prompt at all when the switch is off.
  const unconfirmed = confirmationsOn
    ? classes.filter((c) => !c.confirmed && !c.cover_requested).length
    : 0;

  const roster = (rosters.data ?? [])[0] ?? null;
  const rosterLabel = roster
    ? new Intl.DateTimeFormat("en-GB", { month: "long", timeZone: "UTC" })
        .format(new Date(`${roster.month}T00:00:00Z`))
    : null;
  const availChanges = (changes.data ?? []).length > 0;

  // Decision 45: the collected month is due on the studio's availability_due_day
  // and is not yet in. Shown until it is submitted; changes_requested is handled
  // by its own item above, so this covers only "not sent yet" and "draft".
  const dueDay = (settings.data?.availability_due_day as number | null) ?? 20;
  // Decision 59: the cover rule, stated under the next-week card when
  // confirmations are off (with them on, Home already has its confirm prompt).
  const coverHours = (settings.data?.cover_escalation_hours as number | null) ?? 4;
  // Decision 46 amendment: "due" only when NO submission AND NO covering pattern
  // AND not published. On file (submitted/approved/pattern) → a quiet line, not a
  // nag. changes_requested keeps its own "asked for changes" item above.
  const availCoveredState = (availCovered.data as string | null) ?? "none";
  const availPublished = !!availPub.data;
  const availDue = availCoveredState === "none" && !availPublished;
  const availOnFile = availCoveredState === "submitted"
    || availCoveredState === "approved" || availCoveredState === "pattern";
  const nextMonthLabel = new Intl.DateTimeFormat("en-GB", { month: "long", timeZone: "UTC" })
    .format(new Date(`${nextMonthISO}T00:00:00Z`));
  const dueLabel = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", timeZone: "UTC" })
    .format(new Date(Date.UTC(ty, tm - 1, dueDay)));

  const coverClasses = ((coverNeeded.data as unknown as { classes?: {
    id: string; time: string; date: string; class_name: string; room: string | null; booked: number; capacity: number;
    tier: string | null; flex_deadline_short: string | null;
  }[] } | null)?.classes) ?? [];
  const notifs = ((notifData.data as { items?: NotifItem[] } | null)?.items ?? []).slice(0, 3);
  const announcements = (anns.data ?? []) as unknown as
    { id: string; kind: string; title: string; body: string; link_url: string | null; link_label: string | null }[];
  // Decision 27 amendment: a banner shows as a strip in the portal too (audience
  // instructors/both). No dismissal here — a roster-relevant notice is not
  // something to swipe away, and an instructor has no member row to dismiss it.
  const annBanners = announcements
    .filter((a) => a.kind === "banner")
    .map((a) => ({ id: a.id, title: a.title, linkUrl: a.link_url, linkLabel: a.link_label }));
  const annPosts = announcements.filter((a) => a.kind !== "banner");

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
      label: `Confirm ${unconfirmed} ${unconfirmed === 1 ? "class" : "classes"} coming up` });
  // Decision 59: no "confirm the roster" prompt when confirmations are off.
  if (confirmationsOn && roster && rosterLabel)
    waiting.push({ key: "roster", href: "/instructor/month",
      label: `Your ${rosterLabel} roster is ready to confirm` });
  if (availChanges)
    waiting.push({ key: "avail", href: "/instructor/availability",
      label: "The studio asked for changes to your availability" });
  if (availDue)
    waiting.push({ key: "avail_due", href: "/instructor/availability",
      label: `Your ${nextMonthLabel} availability is due ${dueLabel}` });

  const quiet = !next && waiting.length === 0 && coverClasses.length === 0;

  return (
    <InstructorShell ctx={ctx}>
      {/* Banner announcements (audience instructors/both) — a filled strip at
          the top, no dismiss in the portal. */}
      <AnnounceStrip items={annBanners} dismissible={false} />
      {/* NEXT CLASS */}
      {next ? (
        <Link href={`/instructor/roster/${next.occurrence_id}`} className="m-card block px-4 py-4">
          <div className="flex items-center justify-between gap-2">
            <p className="m-sub text-ink-3">
              {nextWeekLabel ? <>Next class · week of <span className="num">{nextWeekLabel}</span></> : "Next class"}
            </p>
            <ClassTag tier={next.tier} flex={next.flex} committed={next.committed}
                      flexDeadlineShort={next.flex_deadline_short} />
          </div>
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
          <p className="mt-1 text-[15px] leading-6 text-ink">Nothing coming up this week.</p>
          <Link href="/instructor/shifts"
                className="m-sub mt-1 inline-block underline underline-offset-4"
                style={{ color: "var(--accent-text)" }}>See what&apos;s on</Link>
        </div>
      )}

      {/* Decision 59: the one rule, when confirmations are off. */}
      {!confirmationsOn && next && (
        <p className="mt-2 px-1 text-[12.5px] leading-[18px] text-ink-3">
          Can&rsquo;t make a class? Ask for cover at least <span className="num">{coverHours}</span> hours
          before it starts — you can ask a colleague directly and they confirm from their phone.
        </p>
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
                      <span className="flex items-center gap-2">
                        <span className="min-w-0 truncate text-[14px] text-ink">{c.class_name}</span>
                        <ClassTag tier={c.tier} flexDeadlineShort={c.flex_deadline_short} />
                      </span>
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

      {/* Decision 46 amendment: the month's availability is on file — a quiet
          line, not a nag (the studio entered a pattern, or it is submitted). */}
      {availOnFile && (
        <p className="mt-4 px-1 text-[12.5px] leading-[18px] text-ink-3">
          {nextMonthLabel}: on file.
        </p>
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
            {notifs.map((n) => {
              const href = notificationHref(n.template_key, n.payload);
              const cls = "m-card flex items-start gap-3 px-3.5 py-3";
              const body = (
                <>
                  <span className="mt-1.5 h-2 w-2 shrink-0 rounded-full"
                        style={{ background: n.read ? "var(--line-2)" : "var(--lime-text)" }} />
                  <span className="min-w-0 flex-1">
                    <span className={`block text-[14px] leading-5 ${n.read ? "text-ink-2" : "text-ink"}`}>
                      {notifLabel(n.template_key).title}
                    </span>
                    <span className="m-sub block text-ink-3">{relTime(n.created_at)}</span>
                  </span>
                  {href && <span className="self-center shrink-0 text-[18px] leading-none text-ink-3" aria-hidden>›</span>}
                </>
              );
              return (
                <li key={n.id}>
                  {href ? (
                    <Link href={href} className={`${cls} m-press`}>{body}</Link>
                  ) : (
                    <div className={cls}>{body}</div>
                  )}
                </li>
              );
            })}
          </ul>
        </section>
      )}

      {/* ANNOUNCEMENTS — What's-on posts as cards (banners are the strip above) */}
      {annPosts.length > 0 && (
        <section className="mt-5 space-y-3">
          {annPosts.map((a) => (
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
