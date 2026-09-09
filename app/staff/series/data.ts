import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";

/** Archived records are excluded: migration 058 archives a thing so new work stops using it. */
export async function seriesOptions(supabase: SupabaseClient<Database>) {
  const [{ data: classTypes }, { data: rooms }, { data: instructors }] = await Promise.all([
    supabase.from("class_types").select("id, name, default_capacity, duration_minutes")
      .eq("status", "active").order("name"),
    supabase.from("rooms").select("id, name, capacity").eq("status", "active").order("name"),
    supabase.from("instructors").select("id, display_name").eq("status", "active").order("display_name"),
  ]);
  return {
    classTypes: (classTypes ?? []).map((c) => ({
      id: c.id, name: c.name, capacity: c.default_capacity, duration: c.duration_minutes,
    })),
    rooms: (rooms ?? []).map((r) => ({ id: r.id, name: r.name, capacity: r.capacity })),
    instructors: (instructors ?? []).map((i) => ({ id: i.id, name: i.display_name })),
  };
}

/**
 * Today and tomorrow IN THE STUDIO'S ZONE, as strings.
 *
 * `toISOString()` on a local-midnight Date shifts back a day east of Greenwich,
 * which is the bug the fill screen's iso() exists to avoid. Formatted from the
 * parts, and formatted on the server — a Date or a formatter crossing into a
 * client component is a runtime error TypeScript will not warn about.
 */
export function localDates(timeZone: string) {
  const fmt = (d: Date) => {
    const p = new Intl.DateTimeFormat("en-CA", {
      timeZone, year: "numeric", month: "2-digit", day: "2-digit",
    }).formatToParts(d);
    const get = (t: string) => p.find((x) => x.type === t)!.value;
    return `${get("year")}-${get("month")}-${get("day")}`;
  };
  const now = new Date();
  return { today: fmt(now), tomorrow: fmt(new Date(now.getTime() + 86_400_000)) };
}
