import { AppShell, Empty, NavLink, Rows, SectionLabel } from "@/components/ui";
import { staffScreen } from "@/lib/screen";
import { fmtTime, fmtDayLong } from "@/lib/time";
import { ApplyForm, WithdrawForm } from "./form";

export const dynamic = "force-dynamic";

/**
 * The instructor's screen: shifts nobody is teaching yet.
 *
 * Decision 17 in one page. They ask; staff decide. Their stated availability is
 * shown as context beside each shift and never used to hide one — Decision 9's
 * rule that a hard block gets worked around by not using the feature applies
 * just as much to applying as it does to being assigned.
 */
export default async function Shifts() {
  const screen = await staffScreen("/shifts");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  const { data: me } = await supabase.rpc("auth_instructor_id", { target: ctx.studioId });
  if (!me) {
    return (
      <AppShell {...shell} title="Open shifts">
        <Empty>
          This is the instructors&rsquo; screen. You are signed in as{" "}
          {ctx.role.replace("_", " ")}.{" "}
          <NavLink href="/shifts/applications">See who has applied</NavLink>
        </Empty>
      </AppShell>
    );
  }

  const [{ data: open }, { data: mine }, { data: teaching }] = await Promise.all([
    supabase.from("class_occurrences")
      .select("id, name, starts_at, ends_at, capacity, booked_count, staffing, rooms(name)")
      .in("staffing", ["open", "pending_approval"])
      .eq("status", "scheduled")
      .gt("starts_at", new Date().toISOString())
      .order("starts_at").limit(40),
    supabase.from("shift_applications")
      .select("id, occurrence_id, status").eq("instructor_id", me).eq("status", "pending"),
    supabase.from("class_occurrences")
      .select("id, name, starts_at, booked_count, rooms(name)")
      .eq("instructor_id", me).eq("status", "scheduled")
      .gt("starts_at", new Date().toISOString())
      .order("starts_at").limit(20),
  ]);

  const applied = new Set((mine ?? []).map((a) => a.occurrence_id));

  // Availability is context, not a filter. Asked per shift so the answer is the
  // same one the studio will see on the application.
  const availability = new Map<string, boolean>();
  await Promise.all((open ?? []).map(async (o) => {
    const { data } = await supabase.rpc("instructor_available_at", {
      p_instructor_id: me, p_starts_at: o.starts_at, p_ends_at: o.ends_at,
    });
    availability.set(o.id, data !== false);
  }));

  const when = (iso: string) =>
    `${fmtDayLong(iso, ctx.timeZone)}, ${fmtTime(iso, ctx.timeZone)}`;

  return (
    <AppShell {...shell} title="Open shifts">
      <SectionLabel>Nobody is teaching these yet</SectionLabel>
      {(open ?? []).length === 0 ? (
        <Empty>No open shifts right now. The studio will publish them here.</Empty>
      ) : (
        <Rows>
          {(open ?? []).map((o) => {
            const free = availability.get(o.id) ?? true;
            const already = applied.has(o.id);
            return (
              <div key={o.id} className="flex items-start justify-between gap-4 px-3 py-3">
                <span className="min-w-0">
                  <span className="block truncate text-[14px] leading-5 text-ink">{o.name}</span>
                  <span className="block text-[12px] leading-4 text-ink-3">
                    {when(o.starts_at)}
                    {o.rooms?.name ? ` · ${o.rooms.name}` : ""}
                    {" · "}<span className="num">{o.booked_count}</span> booked
                  </span>
                  {!free && (
                    <span className="mt-0.5 block text-[12px] leading-4"
                          style={{ color: "var(--amber-deep)" }}>
                      Outside the availability you gave us — you can still ask.
                    </span>
                  )}
                </span>
                {already ? (
                  <span className="shrink-0 text-[12px] leading-4 text-ink-3">Asked for</span>
                ) : (
                  <ApplyForm occurrenceId={o.id} outside={!free} />
                )}
              </div>
            );
          })}
        </Rows>
      )}

      <div className="mt-8">
        <SectionLabel>You are teaching</SectionLabel>
        {(teaching ?? []).length === 0 ? (
          <Empty>Nothing coming up.</Empty>
        ) : (
          <Rows>
            {(teaching ?? []).map((o) => (
              <div key={o.id} className="flex items-start justify-between gap-4 px-3 py-3">
                <span className="min-w-0">
                  <span className="block truncate text-[14px] leading-5 text-ink">{o.name}</span>
                  <span className="block text-[12px] leading-4 text-ink-3">
                    {when(o.starts_at)}
                    {o.rooms?.name ? ` · ${o.rooms.name}` : ""}
                    {" · "}<span className="num">{o.booked_count}</span> booked
                  </span>
                </span>
                <WithdrawForm occurrenceId={o.id} />
              </div>
            ))}
          </Rows>
        )}
      </div>
    </AppShell>
  );
}
