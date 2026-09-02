import { AppShell, Empty, NavLink, Rows, SectionLabel } from "@/components/ui";
import { staffScreen } from "@/lib/screen";
import { fmtTime, fmtDayLong } from "@/lib/time";
import { DecideForm } from "../form";

export const dynamic = "force-dynamic";

/**
 * Everyone waiting on an answer, in one place.
 *
 * Grouped by the shift rather than listed flat, because the decision is per
 * shift: approving one person declines the others for that class, and seeing
 * them together is what makes that obvious before you click.
 *
 * A shift that nobody has applied for is shown too. An empty column is the
 * thing most worth acting on, and a screen that only lists applications hides
 * exactly the classes with none.
 */
export default async function Applications() {
  const screen = await staffScreen("/shifts/applications");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!["owner", "manager"].includes(ctx.role)) {
    return (
      <AppShell {...shell} title="Applications">
        <Empty>
          Approving a shift is the owner&rsquo;s and managers&rsquo; to do. You
          are signed in as {ctx.role.replace("_", " ")}.
        </Empty>
      </AppShell>
    );
  }

  const [{ data: apps }, { data: unstaffed }] = await Promise.all([
    supabase.from("shift_applications")
      .select("id, occurrence_id, applied_at, note, instructors(display_name), class_occurrences(name, starts_at, ends_at, booked_count, rooms(name))")
      .eq("status", "pending")
      .order("applied_at"),
    supabase.from("class_occurrences")
      .select("id, name, starts_at, booked_count, rooms(name)")
      .eq("staffing", "open").eq("status", "scheduled")
      .gt("starts_at", new Date().toISOString())
      .order("starts_at").limit(30),
  ]);

  const byOcc = new Map<string, typeof apps>();
  for (const a of apps ?? []) {
    const list = byOcc.get(a.occurrence_id) ?? [];
    list.push(a);
    byOcc.set(a.occurrence_id, list as typeof apps);
  }

  const when = (iso: string) => `${fmtDayLong(iso, ctx.timeZone)}, ${fmtTime(iso, ctx.timeZone)}`;

  return (
    <AppShell {...shell} title="Applications"
              actions={<NavLink href="/schedule">Back to the calendar</NavLink>}>
      <SectionLabel>Waiting on you</SectionLabel>
      {byOcc.size === 0 ? (
        <Empty>Nobody is waiting on an answer.</Empty>
      ) : (
        <div className="space-y-5">
          {[...byOcc.entries()].map(([occId, list]) => {
            const occ = list?.[0]?.class_occurrences;
            return (
              <div key={occId}>
                <p className="mb-1.5 text-[13px] font-medium leading-[18px] text-ink">
                  {occ?.name}
                  <span className="ml-2 font-normal text-ink-3">
                    {occ ? when(occ.starts_at) : ""}
                    {occ?.rooms?.name ? ` · ${occ.rooms.name}` : ""}
                    {occ ? ` · ${occ.booked_count} booked` : ""}
                  </span>
                </p>
                {(list?.length ?? 0) > 1 && (
                  <p className="mb-1.5 text-[12px] leading-4 text-ink-3">
                    {list!.length} people want this one. Approving one declines
                    the rest and tells them.
                  </p>
                )}
                <Rows>
                  {(list ?? []).map((a) => (
                    <div key={a.id} className="flex items-start justify-between gap-4 px-3 py-3">
                      <span className="min-w-0">
                        <span className="block truncate text-[14px] leading-5 text-ink">
                          {a.instructors?.display_name}
                        </span>
                        {a.note && (
                          <span className="block text-[12px] leading-4 text-ink-2">{a.note}</span>
                        )}
                      </span>
                      <DecideForm applicationId={a.id} />
                    </div>
                  ))}
                </Rows>
              </div>
            );
          })}
        </div>
      )}

      <div className="mt-8">
        <SectionLabel>Open, and nobody has asked</SectionLabel>
        {(unstaffed ?? []).filter((o) => !byOcc.has(o.id)).length === 0 ? (
          <Empty>Every open shift has somebody waiting.</Empty>
        ) : (
          <Rows>
            {(unstaffed ?? []).filter((o) => !byOcc.has(o.id)).map((o) => (
              <div key={o.id} className="flex items-start justify-between gap-4 px-3 py-3">
                <span className="min-w-0">
                  <span className="block truncate text-[14px] leading-5 text-ink">{o.name}</span>
                  <span className="block text-[12px] leading-4 text-ink-3">
                    {when(o.starts_at)}
                    {o.rooms?.name ? ` · ${o.rooms.name}` : ""}
                    {" · "}<span className="num">{o.booked_count}</span> booked
                  </span>
                </span>
                {o.booked_count > 0 && (
                  <span className="shrink-0 rounded-full px-2 py-0.5 text-[11px] leading-4"
                        style={{ background: "var(--coral-tint)", color: "var(--ink)" }}>
                    members booked
                  </span>
                )}
              </div>
            ))}
          </Rows>
        )}
      </div>
    </AppShell>
  );
}
