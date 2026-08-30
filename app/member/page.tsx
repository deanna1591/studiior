import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getMemberContext } from "@/lib/auth";
import { Shell } from "@/components/ui";
import { addDays, fmtDayLabel, fmtTime, weekStart, zonedDateKey } from "@/lib/time";
import { signOut } from "./actions";
import BookButton from "./book-button";

export const dynamic = "force-dynamic";

export default async function MemberSchedule() {
  const ctx = await getMemberContext();
  if (!ctx) redirect("/login");

  const supabase = createClient();
  const from = new Date();
  const to = addDays(weekStart(from, ctx.timeZone, 1), 7);

  // occ_member_read restricts this to scheduled classes in the member's own
  // studio. No studio filter is written here because the policy is the filter.
  const { data: occurrences } = await supabase
    .from("class_occurrences")
    .select("id, name, starts_at, capacity, booked_count, instructors!instructor_id(display_name)")
    .gte("starts_at", from.toISOString())
    .lt("starts_at", to.toISOString())
    .order("starts_at");

  const { data: mine } = await supabase
    .from("bookings")
    .select("occurrence_id, status, waitlist_position")
    .in("status", ["booked", "waitlisted"]);

  const byOccurrence = new Map((mine ?? []).map((b) => [b.occurrence_id, b]));

  const byDay = new Map<string, NonNullable<typeof occurrences>>();
  for (const o of occurrences ?? []) {
    const key = zonedDateKey(o.starts_at, ctx.timeZone);
    if (!byDay.has(key)) byDay.set(key, []);
    byDay.get(key)!.push(o);
  }

  return (
    <Shell
      title={ctx.studioName}
      subtitle={`Hello ${ctx.name} — book a class`}
      right={
        <form action={signOut}>
          <button className="text-ink-2 underline underline-offset-4">Sign out</button>
        </form>
      }
    >
      {byDay.size === 0 && <p className="text-sm text-ink-3">No classes scheduled.</p>}

      <div className="space-y-6">
        {[...byDay.entries()].map(([day, list]) => (
          <section key={day}>
            <h2 className="mb-2 text-xs font-semibold uppercase tracking-wide text-ink-3">
              {fmtDayLabel(list[0].starts_at, ctx.timeZone)}
            </h2>
            <ul className="divide-y divide-line rounded border border-line bg-white">
              {list.map((o) => {
                const booking = byOccurrence.get(o.id);
                const spots = o.capacity - o.booked_count;
                return (
                  <li key={o.id} className="flex items-center justify-between gap-4 px-3 py-3">
                    <div>
                      <div className="text-sm font-medium">
                        {fmtTime(o.starts_at, ctx.timeZone)} · {o.name}
                      </div>
                      <div className="text-xs text-ink-3">
                        {o.instructors?.display_name ?? "Unassigned"} ·{" "}
                        {spots > 0 ? `${spots} spot${spots === 1 ? "" : "s"} left` : "Full — waitlist"}
                      </div>
                    </div>
                    {booking ? (
                      <span className="text-sm font-medium text-lime-text">
                        {booking.status === "waitlisted"
                          ? `Waitlist #${booking.waitlist_position}`
                          : "Booked ✓"}
                      </span>
                    ) : (
                      <BookButton occurrenceId={o.id} full={spots <= 0} />
                    )}
                  </li>
                );
              })}
            </ul>
          </section>
        ))}
      </div>
    </Shell>
  );
}
