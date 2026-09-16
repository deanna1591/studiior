import Link from "next/link";
import { instructorScreen, studioToday } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";
import { ApplyForShift, ClaimClass, WithdrawApplication } from "../actions-ui";

export const dynamic = "force-dynamic";

type ClaimRow = {
  id: string; starts_at: string; date: string; time: string;
  class_name: string; duration_minutes: number; room: string | null;
  spaces_left: number; capacity: number; tier: string;
  qualified: boolean; available: boolean; valid: boolean; mine: boolean; clashes: boolean;
};
type MonthBlock = { month: string; can_claim: boolean; reason: string | null; classes: ClaimRow[] };
type Horizon = {
  horizon_days: number; core_cap: number;
  standing: { core: number; flex: number };
  months: MonthBlock[];
};

// ● core, ○ flex, ◆ always — a shape, not a colour (the calendar's rule; colour
// is already staffing there and the studio's own class colour on the grid).
const tierMark = (t: string) => (t === "flex" ? "○" : t === "always" ? "◆" : "●");
const tierWord = (t: string) => (t === "flex" ? "flex" : t === "always" ? "always runs" : "core");

/**
 * SHIFTS — two models, decided by the studio's `claiming_enabled` switch.
 *
 * ASSIGNED (off): Decision 17 open shifts — apply, staff approve. The list is
 * every open class, no eligibility filter.
 *
 * CLAIMING (on, migration 149): the studio publishes UNASSIGNED classes and the
 * instructor CLAIMS them across the whole occurrence horizon — further ahead
 * than members book (members are held to booking_window_days; there is no
 * publication reveal, because month_published is true when publication is off).
 * One section per month: the classes they can take, or — for a month they have
 * not sent availability for — "send it in and these open up", never a blank list.
 * Core claims are capped per week (soft: "ask anyway"); flex is unlimited.
 */
export default async function ShiftsPage() {
  const { ctx, supabase } = await instructorScreen();
  const { data: claimingOn } = await supabase.rpc("claiming_enabled", { p_studio_id: ctx.studio_id });

  // ---- CLAIMING MODEL -------------------------------------------------------
  if (claimingOn) {
    const { data } = await supabase.rpc("instructor_claim_horizon", { p_instructor_id: ctx.instructor_id });
    const hz = data as unknown as Horizon | null;
    const months = hz?.months ?? [];
    const mineCount = months.reduce((n, m) => n + m.classes.filter((c) => c.mine).length, 0);

    const monthLabel = (m: string) =>
      new Intl.DateTimeFormat("en-GB", { month: "long", year: "numeric", timeZone: "UTC" })
        .format(new Date(`${m}-01T12:00:00Z`));
    const monthName = (m: string) =>
      new Intl.DateTimeFormat("en-GB", { month: "long", timeZone: "UTC" })
        .format(new Date(`${m}-01T12:00:00Z`));
    const dayLabel = (iso: string) =>
      new Intl.DateTimeFormat("en-GB", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" })
        .format(new Date(`${iso}T12:00:00Z`));

    return (
      <InstructorShell ctx={ctx} title="Claim classes" badges={{ "/instructor/shifts": mineCount }}>
        {/* Where they stand this week — said once, at the top. */}
        <div className="m-card mb-4 px-4 py-3">
          <p className="text-[14px] leading-5 text-ink">
            This week: <span className="num font-semibold">{hz?.standing.core ?? 0}</span> of{" "}
            <span className="num">{hz?.core_cap ?? 0}</span> core{" "}
            {(hz?.core_cap ?? 0) === 1 ? "class" : "classes"} claimed.
            {(hz?.standing.flex ?? 0) > 0 && (
              <> <span className="num">{hz?.standing.flex}</span> flex.</>
            )}
          </p>
          <p className="m-sub mt-0.5 text-ink-3">
            Core is capped per week; flex has no limit. The studio approves every claim.
          </p>
        </div>

        {months.length === 0 && (
          <div className="m-card px-4 py-6">
            <p className="text-[15px] leading-6 text-ink">Nothing to claim just now.</p>
          </div>
        )}

        {months.map((mb) => (
          <section key={mb.month} className="mb-5">
            <h2 className="m-sub mb-2 px-1 font-semibold text-ink-2">{monthLabel(mb.month)}</h2>

            {!mb.can_claim ? (
              // The actionable state — NOT a blank month. Same relationship the
              // validity window enforces: no availability for that month, no
              // claiming into it, so ask for the availability.
              <div className="m-card px-4 py-3.5">
                <p className="text-[15px] leading-[22px] text-ink">
                  Send us your {monthName(mb.month)} availability and these open up.
                </p>
                <p className="m-sub mt-0.5 text-ink-3">
                  We can only put you on classes in a month you have told us you can work.
                </p>
                <Link href="/instructor/availability"
                      className="m-tap mt-3 inline-flex items-center text-[14px] font-medium text-[color:var(--accent-text)] underline underline-offset-4">
                  Add {monthName(mb.month)} availability →
                </Link>
              </div>
            ) : mb.classes.length === 0 ? (
              <div className="m-card px-4 py-4">
                <p className="text-[14px] leading-5 text-ink-2">Nothing open in {monthName(mb.month)} right now.</p>
              </div>
            ) : (
              <ul className="space-y-2">
                {mb.classes.map((c) => (
                  <li key={c.id} className="m-card px-3 py-3">
                    <div className="flex items-baseline gap-3">
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-[15px] leading-5 text-ink">
                          <span aria-hidden className="text-ink-2">{tierMark(c.tier)}</span>{" "}
                          {c.class_name}
                        </span>
                        <span className="m-sub block text-ink-3">
                          {dayLabel(c.date)} · <span className="num">{c.time}</span>
                          {c.room ? ` · ${c.room}` : ""} · {tierWord(c.tier)}
                        </span>
                      </span>
                      <span className="num shrink-0 text-[13px] leading-5 text-ink-2">
                        {c.capacity - c.spaces_left}/{c.capacity}
                      </span>
                    </div>

                    {/* Why it might not be a clean fit — labelled, never hidden. */}
                    {(!c.qualified || !c.available || c.clashes) && !c.mine && (
                      <p className="m-sub mt-1 text-ink-3">
                        {[
                          !c.qualified && "not one you are down to teach",
                          c.clashes && "clashes with another you are taking",
                          !c.available && "outside the hours you gave us",
                        ].filter(Boolean).join(" · ")}
                      </p>
                    )}

                    {c.mine ? (
                      <>
                        <p className="mt-1.5 text-[12px] leading-[17px] text-ink-2">
                          You have claimed it. The studio decides.
                        </p>
                        <WithdrawApplication occurrenceId={c.id} />
                      </>
                    ) : (
                      <ClaimClass occurrenceId={c.id} />
                    )}
                  </li>
                ))}
              </ul>
            )}
          </section>
        ))}
      </InstructorShell>
    );
  }

  // ---- ASSIGNED MODEL (Decision 17 open shifts) -----------------------------
  studioToday(ctx.timezone);
  const [{ data: open }, { data: mine }] = await Promise.all([
    supabase.from("class_occurrences")
      .select("id, name, starts_at, ends_at, capacity, booked_count, rooms(name)")
      .eq("staffing", "open").eq("status", "scheduled")
      .gte("starts_at", new Date().toISOString())
      .order("starts_at").limit(40),
    supabase.from("shift_applications")
      .select("occurrence_id, status, applied_at")
      .eq("instructor_id", ctx.instructor_id).eq("status", "pending"),
  ]);

  const applied = new Set((mine ?? []).map((a) => a.occurrence_id));
  const when = (iso: string) =>
    new Intl.DateTimeFormat("en-GB", {
      timeZone: ctx.timezone, weekday: "short", day: "numeric", month: "short",
      hour: "2-digit", minute: "2-digit", hour12: false,
    }).format(new Date(iso));

  return (
    <InstructorShell ctx={ctx} title="Open shifts" badges={{ "/instructor/shifts": applied.size }}>
      {(open ?? []).length === 0 ? (
        <div className="m-card px-4 py-6">
          <p className="text-[15px] leading-6 text-ink">Nothing going at the moment.</p>
          <p className="m-sub mt-1 text-ink-2">
            When the studio has a class with nobody down to teach it, it appears
            here and you can put your name forward.
          </p>
        </div>
      ) : (
        <ul className="space-y-2">
          {(open ?? []).map((o) => (
            <li key={o.id} className="m-card px-3 py-3">
              <div className="flex items-baseline gap-3">
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-[15px] leading-5 text-ink">{o.name}</span>
                  <span className="m-sub block text-ink-3">
                    {when(o.starts_at)}
                    {o.rooms?.name ? ` · ${o.rooms.name}` : ""}
                  </span>
                </span>
                <span className="num shrink-0 text-[13px] leading-5 text-ink-2">
                  {o.booked_count}/{o.capacity}
                </span>
              </div>
              {applied.has(o.id) ? (
                <>
                  <p className="mt-1.5 text-[12px] leading-[17px] text-ink-2">
                    You have put your name forward. Staff decide.
                  </p>
                  <WithdrawApplication occurrenceId={o.id} />
                </>
              ) : (
                <ApplyForShift occurrenceId={o.id} />
              )}
            </li>
          ))}
        </ul>
      )}
      <p className="m-sub mt-5 text-ink-3">
        Staff approve every one of these. Applying does not book you in, and
        approving somebody withdraws the rest for that class.
      </p>
    </InstructorShell>
  );
}
