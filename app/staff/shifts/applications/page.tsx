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

  const [{ data: apps }, { data: unstaffed }, { data: conflictsData }] = await Promise.all([
    supabase.from("shift_applications")
      .select("id, occurrence_id, instructor_id, applied_at, note, instructors(display_name), class_occurrences(name, starts_at, ends_at, booked_count, rooms(name))")
      .eq("status", "pending")
      .order("applied_at"),
    supabase.from("class_occurrences")
      .select("id, name, starts_at, booked_count, rooms(name)")
      .eq("staffing", "open").eq("status", "scheduled")
      .gt("starts_at", new Date().toISOString())
      .order("starts_at").limit(30),
    // B (155): future classes whose assigned instructor has since narrowed their
    // availability out from under them. Same weight as an unstaffed class — the
    // instructor is still on it, so it is a decision to reassign or open, not an
    // auto-unstaffing.
    supabase.rpc("availability_conflicts", { p_studio_id: ctx.studioId }),
  ]);
  const conflicts = ((conflictsData as unknown as { conflicts: {
    occurrence_id: string; name: string; local_when: string; instructor_name: string;
    room: string | null; booked: number; starts_at: string;
  }[] } | null)?.conflicts) ?? [];
  const conflictDay = (iso: string) =>
    new Intl.DateTimeFormat("en-CA", { timeZone: ctx.timeZone }).format(new Date(iso));

  const byOcc = new Map<string, typeof apps>();
  for (const a of apps ?? []) {
    const list = byOcc.get(a.occurrence_id) ?? [];
    list.push(a);
    byOcc.set(a.occurrence_id, list as typeof apps);
  }

  // Reliability, as plain context beside each name — "applied for 14, withdrew
  // from 3". Not a score, not a ranking; it changes nothing about who can be
  // approved. Studiior measures, the studio judges.
  const applicantIds = [...new Set((apps ?? []).map((a) => a.instructor_id))];
  const relEntries = await Promise.all(applicantIds.map(async (id) => {
    const { data } = await supabase.rpc("instructor_reliability", { p_instructor_id: id });
    return [id, data as unknown as { summary: string; withdrawn: number; short_notice: number } | null] as const;
  }));
  const reliability = new Map(relEntries);

  // Claiming (149): when the studio runs claiming, each claimant carries where
  // they stand — "core · 1 of 3 this week", or "over cap · 3 of 3" — which is the
  // fact that decides a core approval. Fetched per shift (the tier and cap are
  // per occurrence). Absent for a studio on the assigned model.
  type Claimant = {
    instructor_id: string; core_this_week: number; core_cap: number;
    flex_this_week: number; over_cap: boolean; qualified: boolean;
  };
  const { data: claimingOn } = await supabase.rpc("claiming_enabled", { p_studio_id: ctx.studioId });
  const rankByOcc = new Map<string, { tier: string; byInstr: Map<string, Claimant> }>();
  if (claimingOn) {
    const entries = await Promise.all([...byOcc.keys()].map(async (occId) => {
      const { data } = await supabase.rpc("claim_ranking", { p_occurrence_id: occId });
      const r = data as unknown as { tier: string; claimants: Claimant[] } | null;
      return [occId, {
        tier: r?.tier ?? "core",
        byInstr: new Map((r?.claimants ?? []).map((c) => [c.instructor_id, c])),
      }] as const;
    }));
    for (const [k, v] of entries) rankByOcc.set(k, v);
  }

  const when = (iso: string) => `${fmtDayLong(iso, ctx.timeZone)}, ${fmtTime(iso, ctx.timeZone)}`;

  return (
    <AppShell {...shell} title="Applications"
              actions={<NavLink href="/schedule">Back to the schedule</NavLink>}>
      {conflicts.length > 0 && (
        <div className="mb-6">
          <div className="max-w-[62ch] rounded border-l-[3px] px-3.5 py-3"
               style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }} role="alert">
            <p className="text-[13px] leading-[19px] text-ink">
              <span className="font-semibold">
                <span className="num">{conflicts.length}</span>{" "}
                {conflicts.length === 1 ? "class is" : "classes are"} assigned to an instructor
                who has since removed those hours from their availability.
              </span>{" "}
              They are still on it until you act — reassign or open each.
            </p>
          </div>
          <Rows>
            {conflicts.map((c) => (
              <div key={c.occurrence_id} className="flex items-start justify-between gap-4 px-3 py-3">
                <span className="min-w-0">
                  <span className="block truncate text-[14px] leading-5 text-ink">{c.name}</span>
                  <span className="block text-[12px] leading-4 text-ink-3">
                    {c.instructor_name} · {c.local_when}
                    {c.room ? ` · ${c.room}` : ""}
                    {c.booked > 0 && <> · <span className="num">{c.booked}</span> booked</>}
                  </span>
                </span>
                <span className="flex shrink-0 items-center gap-3 text-[12px]">
                  <NavLink href={`/schedule?d=${conflictDay(c.starts_at)}`}>Reassign</NavLink>
                  <NavLink href={`/roster/${c.occurrence_id}`}>Open</NavLink>
                </span>
              </div>
            ))}
          </Rows>
        </div>
      )}

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
                        {(() => {
                          const r = reliability.get(a.instructor_id);
                          if (!r || r.summary === "No applications yet") return null;
                          return (
                            <span className="mt-0.5 block text-[12px] leading-4 text-ink-3">
                              {r.summary}
                              {r.short_notice > 0 && (
                                <span className="text-ink-2">
                                  {" "}· {r.short_notice} at short notice
                                </span>
                              )}
                            </span>
                          );
                        })()}
                        {claimingOn && (() => {
                          const rank = rankByOcc.get(occId);
                          const c = rank?.byInstr.get(a.instructor_id);
                          if (!c) return null;
                          const core = rank!.tier === "core";
                          return (
                            <span className="mt-0.5 block text-[12px] leading-4 text-ink-3">
                              {core ? (
                                <>core · <span className="num">{c.core_this_week}</span> of{" "}
                                  <span className="num">{c.core_cap}</span> this week
                                  {c.over_cap && <span className="text-ink-2"> · over cap</span>}</>
                              ) : (
                                <>{rank!.tier === "flex" ? "flex" : "always"} · <span className="num">{c.flex_this_week}</span> flex this week</>
                              )}
                              {!c.qualified && <span className="text-ink-2"> · not down to teach this</span>}
                            </span>
                          );
                        })()}
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
