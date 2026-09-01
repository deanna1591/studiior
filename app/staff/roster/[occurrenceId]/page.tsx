import Link from "next/link";
import { notFound } from "next/navigation";
import { staffScreen } from "@/lib/screen";
import { AppShell, Empty, NavLink, Rows, SectionLabel } from "@/components/ui";
import { HealthChip, bandOf } from "@/components/health-band";
import { fmtDayLong, fmtTime, relativeDayName } from "@/lib/time";
import CheckInButton from "./check-in-button";
import CodeCheckIn from "./code-check-in";
import StaffAvatar from "@/components/staff-avatar";
import { signAvatars } from "@/lib/avatars";

export const dynamic = "force-dynamic";

export default async function Roster({ params }: { params: { occurrenceId: string } }) {
  const screen = await staffScreen("/roster");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  const { data: occ } = await supabase
    .from("class_occurrences")
    .select("id, name, starts_at, capacity, booked_count, waitlist_count, status, instructors!instructor_id(display_name), rooms(name)")
    .eq("id", params.occurrenceId)
    .maybeSingle();
  if (!occ) notFound();

  const [{ data: bookings }, { data: checkIns }] =
    await Promise.all([
      supabase
        .from("bookings")
        .select("id, status, payment_source, waitlist_position, member_id, override_reason, members(first_name, last_name, preferred_name, avatar_url, health_band, health_reason)")
        .eq("occurrence_id", params.occurrenceId)
        .order("waitlist_position", { ascending: true, nullsFirst: true })
        .order("booked_at"),
      supabase.from("check_ins").select("booking_id").eq("occurrence_id", params.occurrenceId),
    ]);

  // One round trip for the whole roster rather than one signed URL per row.
  const avatars = await signAvatars(supabase, (bookings ?? []).map((b) => b.members?.avatar_url));

  const checkedIn = new Set((checkIns ?? []).map((c) => c.booking_id));
  const booked = (bookings ?? []).filter((b) => ["booked", "attended", "no_show"].includes(b.status));
  const waitlisted = (bookings ?? []).filter((b) => b.status === "waitlisted");
  const inCount = booked.filter((b) => checkedIn.has(b.id) || b.status === "attended").length;

  const day = relativeDayName(occ.starts_at, ctx.timeZone) ?? fmtDayLong(occ.starts_at, ctx.timeZone);

  return (
    <AppShell
      {...shell}
      title={occ.name}
      actions={<NavLink href="/">Back to schedule</NavLink>}
    >
      {/* The facts of the class, as a line of text rather than a row of stat
          cards. Four numbers do not need four boxes. */}
      <p className="mb-5 text-[13px] leading-[20px] text-ink-2">
        {day} at <span className="num text-ink">{fmtTime(occ.starts_at, ctx.timeZone)}</span>
        {" · "}{occ.instructors?.display_name ?? "No instructor"}
        {occ.rooms?.name ? ` · ${occ.rooms.name}` : ""}
        {" · "}
        <span className="num text-ink">{occ.booked_count}/{occ.capacity}</span> booked
        {inCount > 0 && <>, <span className="num text-ink">{inCount}</span> checked in</>}
        {occ.status === "cancelled" && " · this class is cancelled"}
      </p>

      {/* The desk end of the member's rotating code. Without it the QR on
          their phone is a picture nothing can read. */}
      <CodeCheckIn occurrenceId={occ.id} />

      <SectionLabel>Roster</SectionLabel>
      {booked.length === 0 ? (
        <Empty>Nobody has booked yet. They will appear here as they do.</Empty>
      ) : (
        <Rows>
          {booked.map((b) => {
            const band = bandOf(b.members?.health_band);
            // Only the bands that ask something of you. A wall of "healthy"
            // chips would make the colour mean nothing, and the point of the
            // chip here is that front desk sees it while the member is
            // standing in front of them.
            const flag = band === "drifting" || band === "at_risk";
            return (
              <div key={b.id} className="flex items-center justify-between gap-4 px-3 py-2.5">
                <div className="flex min-w-0 items-center gap-2.5">
                  {/* The member's own photograph, so an instructor can put a
                      name to the person walking in. Private bucket: these are
                      signed URLs, and a member who has not uploaded one falls
                      back to initials rather than a grey silhouette. */}
                  <StaffAvatar
                    name={`${b.members?.first_name ?? ""} ${b.members?.last_name ?? ""}`}
                    url={avatars.get(b.members?.avatar_url ?? "") ?? null}
                  />
                  <Link
                    href={`/members/${b.member_id}`}
                    className="truncate text-[14px] leading-5 text-ink underline decoration-line-2 underline-offset-4 hover:decoration-ink"
                  >
                    {b.members?.preferred_name || b.members?.first_name} {b.members?.last_name}
                  </Link>
                  {flag && <HealthChip band={band} />}
                  <span className="hidden truncate text-[12px] leading-4 text-ink-3 sm:block">
                    {b.payment_source?.replace("_", " ") ?? "—"}
                    {b.override_reason ? ` · override: ${b.override_reason}` : ""}
                  </span>
                </div>
                <CheckInButton
                  bookingId={b.id}
                  memberId={b.member_id}
                  occurrenceId={occ.id}
                  alreadyIn={checkedIn.has(b.id) || b.status === "attended"}
                />
              </div>
            );
          })}
        </Rows>
      )}

      {waitlisted.length > 0 && (
        <div className="mt-8">
          <SectionLabel>Waitlist</SectionLabel>
          <Rows>
            {waitlisted.map((b) => (
              <div key={b.id} className="flex items-center gap-3 px-3 py-2.5">
                <span className="num w-6 shrink-0 text-[13px] text-ink-3">
                  {b.waitlist_position}
                </span>
                <span className="truncate text-[14px] leading-5 text-ink">
                  {b.members?.first_name} {b.members?.last_name}
                </span>
              </div>
            ))}
          </Rows>
          <p className="mt-2 text-[12px] leading-4 text-ink-3">
            First in line moves up automatically when someone cancels.
          </p>
        </div>
      )}
    </AppShell>
  );
}
