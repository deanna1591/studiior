import { notFound, redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffAccess, requireOnboarded } from "@/lib/auth";
import StaffAccessGate from "@/components/staff-access-gate";
import { Shell, NavLink } from "@/components/ui";
import { fmtDayLabel, fmtTime } from "@/lib/time";
import CheckInButton from "./check-in-button";

export const dynamic = "force-dynamic";

export default async function Roster({ params }: { params: { occurrenceId: string } }) {
  const access = await getStaffAccess();
  if (access.kind !== "staff") return <StaffAccessGate access={access} />;
  const ctx = requireOnboarded(access.ctx);

  const supabase = createClient();

  const { data: occ } = await supabase
    .from("class_occurrences")
    .select("id, name, starts_at, capacity, booked_count, waitlist_count, status, instructors!instructor_id(display_name)")
    .eq("id", params.occurrenceId)
    .maybeSingle();
  if (!occ) notFound();

  const { data: bookings } = await supabase
    .from("bookings")
    .select("id, status, payment_source, waitlist_position, member_id, override_reason, members(first_name, last_name)")
    .eq("occurrence_id", params.occurrenceId)
    .order("waitlist_position", { ascending: true, nullsFirst: true })
    .order("booked_at");

  const { data: checkIns } = await supabase
    .from("check_ins")
    .select("booking_id")
    .eq("occurrence_id", params.occurrenceId);
  const checkedIn = new Set((checkIns ?? []).map((c) => c.booking_id));

  const booked = (bookings ?? []).filter((b) => ["booked", "attended", "no_show"].includes(b.status));
  const waitlisted = (bookings ?? []).filter((b) => b.status === "waitlisted");

  return (
    <Shell
      title={occ.name}
      subtitle={`${fmtDayLabel(occ.starts_at, ctx.timeZone)} ${fmtTime(occ.starts_at, ctx.timeZone)} · ${occ.instructors?.display_name ?? "Unassigned"} · ${occ.booked_count}/${occ.capacity} booked`}
      right={<NavLink href="/">Back to week</NavLink>}
    >
      <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-stone-500">Roster</h2>
      {booked.length === 0 && <p className="mb-6 text-sm text-stone-500">Nobody booked yet.</p>}
      <ul className="mb-8 divide-y divide-stone-200 rounded border border-stone-200 bg-white">
        {booked.map((b) => (
          <li key={b.id} className="flex items-center justify-between gap-4 px-3 py-2.5">
            <div>
              <div className="text-sm font-medium">
                {b.members?.first_name} {b.members?.last_name}
              </div>
              <div className="text-xs text-stone-500">
                {b.payment_source?.replace("_", " ") ?? "—"}
                {b.override_reason ? ` · override: ${b.override_reason}` : ""}
              </div>
            </div>
            <CheckInButton
              bookingId={b.id}
              memberId={b.member_id}
              occurrenceId={occ.id}
              alreadyIn={checkedIn.has(b.id) || b.status === "attended"}
            />
          </li>
        ))}
      </ul>

      {waitlisted.length > 0 && (
        <>
          <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-stone-500">
            Waitlist ({occ.waitlist_count})
          </h2>
          <ol className="divide-y divide-stone-200 rounded border border-stone-200 bg-white">
            {waitlisted.map((b) => (
              <li key={b.id} className="px-3 py-2 text-sm">
                <span className="mr-2 text-stone-400">#{b.waitlist_position}</span>
                {b.members?.first_name} {b.members?.last_name}
              </li>
            ))}
          </ol>
        </>
      )}
    </Shell>
  );
}
