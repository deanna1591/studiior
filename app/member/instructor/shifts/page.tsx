import { instructorScreen, studioToday } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";
import { ApplyForShift, WithdrawApplication } from "../actions-ui";

export const dynamic = "force-dynamic";

/**
 * OPEN SHIFTS — Decision 17, folded in from /shifts rather than left as a
 * separate address an instructor has to be told about.
 *
 * Apply, and staff approve. There is no "take it": approving one application
 * auto-declines the rest in the same transaction, and that decision is the
 * studio's. An instructor can withdraw a PENDING application — nobody is
 * counting on you before you have been approved — which is a different thing
 * from releasing a class you have been given, and that Decision 18 forbids
 * outright.
 */
export default async function ShiftsPage() {
  const { ctx, supabase } = await instructorScreen();
  const today = studioToday(ctx.timezone);

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
