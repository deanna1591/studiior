import { instructorScreen, studioToday } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";
import { ApplyForShift, WithdrawApplication } from "../actions-ui";
import ClaimCalendar, { type MonthBlock, type Terms } from "@/components/instructor/claim-calendar";

export const dynamic = "force-dynamic";

type Horizon = {
  horizon_days: number; core_cap: number;
  standing: { core: number; flex: number };
  months: MonthBlock[];
};

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
    const [{ data }, { data: t }] = await Promise.all([
      supabase.rpc("instructor_claim_horizon", { p_instructor_id: ctx.instructor_id }),
      supabase.rpc("claim_guarantee_terms", { p_instructor_id: ctx.instructor_id }),
    ]);
    const hz = data as unknown as Horizon | null;
    const months = hz?.months ?? [];
    const mineCount = months.reduce((n, m) => n + m.classes.filter((c) => c.mine).length, 0);

    return (
      <InstructorShell ctx={ctx} title="Claim" badges={{ "/instructor/shifts": mineCount }}>
        <ClaimCalendar
          months={months}
          coreCap={hz?.core_cap ?? 0}
          standingCore={hz?.standing.core ?? 0}
          standingFlex={hz?.standing.flex ?? 0}
          terms={t as unknown as Terms}
          currency={ctx.currency}
          today={studioToday(ctx.timezone)}
          studioName={ctx.studio_name}
        />
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
