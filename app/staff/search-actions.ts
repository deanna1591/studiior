"use server";

import { createClient } from "@/lib/supabase/server";
import { getStaffAccess, isManagerUp } from "@/lib/auth";
import type { SearchItem } from "@/components/dashboard/topbar";

/**
 * 4.1's universal search.
 *
 * A SERVER ACTION RATHER THAN A PRELOADED INDEX. Shipping every member's name
 * down with the page would make the dashboard's payload grow with the studio —
 * fine at Reform Collective's thirty, wrong at two thousand — and would spend
 * it on a box most mornings nobody opens. One query when somebody types.
 *
 * RLS does the scoping, not this function. Every select below runs on the
 * caller's own session, so a manager of one studio searching for a name gets
 * their own studio's rows because the policies say so — not because of the
 * filters here.
 */
export async function searchStudio(q: string): Promise<SearchItem[]> {
  const term = q.trim();
  if (term.length < 2) return [];

  const access = await getStaffAccess();
  if (access.kind !== "staff") return [];
  const ctx = access.ctx;
  const supabase = createClient();
  const like = `%${term.replace(/[%_]/g, (m) => `\\${m}`)}%`;

  // Instructors and front desk may search people and the timetable; the rest
  // is manager-up, matching what the rail offers and what the policies allow.
  const manager = isManagerUp(ctx.role);

  const [members, instructors, occurrences, rooms, classTypes, plans] = await Promise.all([
    ctx.role === "instructor"
      ? Promise.resolve({ data: [] as never[] })
      : supabase.from("members")
          .select("id, first_name, last_name, email, status")
          .or(`first_name.ilike.${like},last_name.ilike.${like},email.ilike.${like}`)
          .limit(8),
    supabase.from("instructors").select("id, display_name, status").ilike("display_name", like).limit(5),
    supabase.from("class_occurrences")
      .select("id, name, starts_at").ilike("name", like)
      .gte("starts_at", new Date(Date.now() - 7 * 864e5).toISOString())
      .order("starts_at").limit(5),
    manager ? supabase.from("rooms").select("id, name").ilike("name", like).limit(4)
            : Promise.resolve({ data: [] as never[] }),
    manager ? supabase.from("class_types").select("id, name").ilike("name", like).limit(4)
            : Promise.resolve({ data: [] as never[] }),
    manager ? supabase.from("membership_plans").select("id, name").ilike("name", like).limit(4)
            : Promise.resolve({ data: [] as never[] }),
  ]);

  const out: SearchItem[] = [];
  for (const m of members.data ?? []) {
    out.push({
      label: `${m.first_name} ${m.last_name}`,
      sub: m.email ?? null,
      href: `/members/${m.id}`,
      group: "Member",
    });
  }
  for (const i of instructors.data ?? []) {
    out.push({
      label: i.display_name,
      sub: i.status === "archived" ? "Archived" : null,
      href: `/instructors/${i.id}`,
      group: "Instructor",
    });
  }
  for (const o of occurrences.data ?? []) {
    out.push({
      label: o.name,
      sub: new Intl.DateTimeFormat("en-GB", {
        timeZone: ctx.timeZone, weekday: "short", day: "numeric",
        month: "short", hour: "2-digit", minute: "2-digit", hour12: false,
      }).format(new Date(o.starts_at)),
      href: `/roster/${o.id}`,
      group: "Class",
    });
  }
  for (const r of rooms.data ?? []) out.push({ label: r.name, sub: null, href: `/rooms/${r.id}`, group: "Room" });
  for (const c of classTypes.data ?? []) out.push({ label: c.name, sub: null, href: `/class-types/${c.id}`, group: "Class type" });
  for (const p of plans.data ?? []) out.push({ label: p.name, sub: null, href: `/plans/${p.id}`, group: "Plan" });

  return out;
}
