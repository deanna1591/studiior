import { redirect } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getStaffAccess, requireOnboarded, isManagerUp } from "@/lib/auth";
import StaffAccessGate from "@/components/staff-access-gate";
import { Shell, NavLink } from "@/components/ui";
import { signOut } from "./actions";
import SetupChecklist, { type SetupState } from "./checklist";
import { addDays, fmtDayLabel, fmtTime, weekStart, zonedDateKey } from "@/lib/time";

export const dynamic = "force-dynamic";

export default async function StaffWeek({
  searchParams,
}: {
  searchParams: { week?: string };
}) {
  const access = await getStaffAccess();
  if (access.kind !== "staff") return <StaffAccessGate access={access} />;
  const ctx = requireOnboarded(access.ctx);

  const offset = Number(searchParams.week ?? 0) || 0;
  const from = weekStart(new Date(), ctx.timeZone, offset);
  const to = addDays(from, 7);

  const supabase = createClient();
  const { data: setup } = await supabase.rpc("studio_setup_state", { p_studio_id: ctx.studioId });
  const { data: isPlatformAdmin } = await supabase.rpc("is_platform_admin");

  const { data: occurrences } = await supabase
    .from("class_occurrences")
    .select("id, name, starts_at, capacity, booked_count, status, instructors!instructor_id(display_name), rooms(name)")
    .gte("starts_at", from.toISOString())
    .lt("starts_at", to.toISOString())
    .order("starts_at");

  const days = Array.from({ length: 7 }, (_, i) => addDays(from, i));
  const byDay = new Map<string, NonNullable<typeof occurrences>>();
  for (const o of occurrences ?? []) {
    const key = zonedDateKey(o.starts_at, ctx.timeZone);
    if (!byDay.has(key)) byDay.set(key, []);
    byDay.get(key)!.push(o);
  }

  return (
    <Shell
      title={ctx.studioName}
      subtitle={`Week view · signed in as ${ctx.email} (${ctx.role.replace("_", " ")})`}
      right={
        <>
          {isPlatformAdmin && <NavLink href="/admin">Admin</NavLink>}
          {isManagerUp(ctx.role) && <NavLink href="/plans">Plans</NavLink>}
          {isManagerUp(ctx.role) && <NavLink href="/classes/new">Create a class</NavLink>}
          <form action={signOut}><button className="text-stone-600 underline underline-offset-4">Sign out</button></form>
        </>
      }
    >
      {isManagerUp(ctx.role) && setup && (
        <SetupChecklist state={setup as unknown as SetupState} />
      )}

      <div className="mb-4 flex items-center gap-4 text-sm">
        <NavLink href={`/?week=${offset - 1}`}>← Previous</NavLink>
        <span className="text-stone-500">
          {offset === 0 ? "This week" : offset > 0 ? `+${offset} weeks` : `${offset} weeks`}
        </span>
        <NavLink href={`/?week=${offset + 1}`}>Next →</NavLink>
      </div>

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {days.map((d) => {
          const key = zonedDateKey(d.toISOString(), ctx.timeZone);
          const list = byDay.get(key) ?? [];
          return (
            <div key={key} className="rounded border border-stone-200 bg-white p-3">
              <h2 className="mb-2 text-xs font-semibold uppercase tracking-wide text-stone-500">
                {fmtDayLabel(d.toISOString(), ctx.timeZone)}
              </h2>
              {list.length === 0 && <p className="text-sm text-stone-400">—</p>}
              <ul className="space-y-2">
                {list.map((o) => (
                  <li key={o.id}>
                    <Link
                      href={`/roster/${o.id}`}
                      className="block rounded border border-stone-200 px-2 py-1.5 hover:border-stone-400"
                    >
                      <div className="flex items-baseline justify-between gap-2">
                        <span className="font-medium">{fmtTime(o.starts_at, ctx.timeZone)}</span>
                        <span className={o.booked_count >= o.capacity ? "text-xs text-amber-700" : "text-xs text-stone-500"}>
                          {o.booked_count}/{o.capacity}
                        </span>
                      </div>
                      <div className="text-sm">{o.name}</div>
                      <div className="text-xs text-stone-500">
                        {o.instructors?.display_name ?? "Unassigned"}
                        {o.rooms?.name ? ` · ${o.rooms.name}` : ""}
                        {o.status !== "scheduled" ? ` · ${o.status}` : ""}
                      </div>
                    </Link>
                  </li>
                ))}
              </ul>
            </div>
          );
        })}
      </div>
    </Shell>
  );
}
