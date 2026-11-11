import Link from "next/link";
import { notFound } from "next/navigation";
import { staffScreen } from "@/lib/screen";
import { isManagerUp, isDeskUp } from "@/lib/auth";
import { formatPhone } from "@/lib/phone";
import OpenShift from "../open-shift";
import AssignShift from "../assign-shift";
import CancelClass from "../cancel-class";
import { AppShell, Empty, NavLink, Rows, SectionLabel } from "@/components/ui";
import { HealthChip, bandOf } from "@/components/health-band";
import { fmtDayLong, fmtTime, relativeDayName } from "@/lib/time";
import { computeAssignCandidates } from "@/lib/assign";
import CheckInButton from "./check-in-button";
import CodeCheckIn from "./code-check-in";
import PaperWaiverButton from "./paper-waiver-button";
import MakeFreeButton from "./make-free-button";
import RebookButton from "./rebook-button";
import ToastHost from "@/components/staff/toast-host";
import ReleasePay from "./release-pay";
import RunAnyway from "./run-anyway";
import { canForceCommit, forceCommitMinimum } from "@/lib/force-commit";
import StaffAvatar from "@/components/staff-avatar";
import { signAvatars } from "@/lib/avatars";
import ScrollToMember from "./scroll-to-member";

export const dynamic = "force-dynamic";

export default async function Roster({ params, searchParams }: { params: { occurrenceId: string }; searchParams: { member?: string } }) {
  const screen = await staffScreen("/roster");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  const { data: occ } = await supabase
    .from("class_occurrences")
    .select("id, name, starts_at, ends_at, class_type_id, capacity, booked_count, waitlist_count, status, staffing, instructor_id, assignment_requested_at, assignment_confirmed_at, flex, minimum_bookings, committed_at, guarantee_tier, hidden_from_members, instructors!instructor_id(display_name), rooms(name)")
    .eq("id", params.occurrenceId)
    .maybeSingle();
  if (!occ) notFound();

  // An unstaffed, still-scheduled class is the one this screen can act on:
  // assign somebody, or put it back out to instructors. Compute the candidate
  // list the cover board's way — qualified AND available first, the rest
  // labelled — only when there is actually a gap, so an assigned class pays for
  // none of it.
  const manager = isManagerUp(ctx.role);
  // Decision 94: the desk sees the member's number with tap-to-call / tap-to-text.
  // An instructor does not (the §14 instructor-projection rule stays).
  const desk = isDeskUp(ctx.role);
  const unstaffed = manager && occ.status === "scheduled" && !occ.instructor_id;

  // Decision 30 amendment (b) follow-up: the "Open to first-timers" control
  // moved to the Schedule calendar's class popup — the owner opens classes while
  // looking at the week. It is no longer on the roster page.

  // Speed pass (1 Nov): ONE wave for everything that needs only the occurrence,
  // the params and the role — this was ~6 sequential awaits. The candidate list
  // (only when the class is unstaffed) and the held-pay / settings reads (only
  // for a manager) ride along as conditional promises.
  const [assignBundle, { data: bookings }, { data: checkIns }, { data: guestRows },
         { data: groupRows }, { data: heldPay }, { data: gs }] = await Promise.all([
    unstaffed
      // The same candidate list the calendar's Assign popover uses — one helper,
      // so the two places this control lives cannot disagree.
      ? Promise.all([
          computeAssignCandidates(supabase, occ, ctx.timeZone),
          supabase.from("shift_applications")
            .select("id", { count: "exact", head: true })
            .eq("occurrence_id", occ.id).eq("status", "pending"),
        ]).then(([cands, { count }]) => ({ candidates: cands, pendingApplications: count ?? 0 }))
      : Promise.resolve(null as { candidates: Awaited<ReturnType<typeof computeAssignCandidates>>; pendingApplications: number } | null),
    supabase
      .from("bookings")
      .select("id, status, payment_source, waitlist_position, member_id, override_reason, members(first_name, last_name, preferred_name, avatar_url, health_band, health_reason, waiver_signed_at, phone)")
      .eq("occurrence_id", params.occurrenceId)
      .order("waitlist_position", { ascending: true, nullsFirst: true })
      .order("booked_at"),
    supabase.from("check_ins").select("booking_id, method, distance_m").eq("occurrence_id", params.occurrenceId),
    // Decision 26: who on this roster is a GUEST, and who brought them.
    supabase.from("guest_passes")
      .select("guest_member_id, host_member_id, status")
      .eq("occurrence_id", params.occurrenceId)
      .in("status", ["invited", "confirmed", "attended"]),
    // Decision 76: who on this roster is on a GROUP (Barkada) booking.
    supabase.from("group_bookings")
      .select("member_id, is_host, group_purchases!inner(occurrence_id, membership_plans(name), members(first_name, last_name))")
      .eq("group_purchases.occurrence_id", params.occurrenceId),
    // Decision 28: is this class's pay held (instructor not checked in)?
    manager
      ? supabase.from("instructor_pay_records").select("id")
          .eq("occurrence_id", params.occurrenceId).eq("type", "class").is("confirmed_at", null).maybeSingle()
      : Promise.resolve({ data: null }),
    // Guarantee switches, for Run-anyway and the force-committed line.
    manager
      ? supabase.from("studio_settings")
          .select("guarantees_enabled, flex_enabled, core_min_bookings, flex_min_bookings")
          .eq("studio_id", ctx.studioId).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);
  const candidates = assignBundle?.candidates ?? [];
  const pendingApplications = assignBundle?.pendingApplications ?? 0;

  const guestOf = new Map((guestRows ?? []).map((g) => [g.guest_member_id, g.host_member_id]));
  const groupOf = new Map(
    (groupRows ?? []).map((g) => {
      const gpu = g.group_purchases as unknown as {
        membership_plans: { name: string } | null;
        members: { first_name: string | null; last_name: string | null } | null;
      } | null;
      const host = gpu?.members;
      return [g.member_id as string, {
        isHost: g.is_host as boolean,
        plan: gpu?.membership_plans?.name ?? "Group",
        host: `${host?.first_name ?? ""} ${host?.last_name ?? ""}`.trim() || "a member",
      }];
    }),
  );

  // Decision 22 "Run anyway" + the force-committed line read the guarantee
  // switches (gs, fetched above). The pure helper decides the label from the
  // occurrence + the switches; the RPC is the real boundary.
  const fcSettings = {
    guaranteesEnabled: gs?.guarantees_enabled ?? false,
    flexEnabled: gs?.flex_enabled ?? false,
    coreMin: gs?.core_min_bookings ?? 1,
    flexMin: gs?.flex_min_bookings ?? 1,
    nowMs: Date.now(),
  };
  const fcOcc = {
    flex: occ.flex ?? false,
    guaranteeTier: occ.guarantee_tier ?? null,
    minimumBookings: occ.minimum_bookings ?? null,
    committedAt: occ.committed_at ?? null,
    status: occ.status,
    startsMs: new Date(occ.starts_at).getTime(),
    bookedCount: occ.booked_count,
  };
  const showRunAnyway = manager && canForceCommit(fcOcc, fcSettings) === "run_anyway";
  const runMinimum = showRunAnyway ? forceCommitMinimum(fcOcc, fcSettings) : 0;

  // Decision 30 (c): which booked drop-ins are UNPAID — managers can convert
  // those into the member's free first class. Shown only for a flex/core class
  // that was forced (needs gs, fetched above).
  const dropinIds = manager
    ? (bookings ?? []).filter((b) => b.status === "booked" && b.payment_source === "drop_in").map((b) => b.id)
    : [];
  const memberIds = (bookings ?? []).map((b) => b.member_id).filter(Boolean);
  const forced = manager && occ.committed_at && (occ.flex || (gs?.guarantees_enabled && (occ.guarantee_tier ?? "core") === "core"));

  // Speed pass (1 Nov): ONE wave for the reads that depend on the bookings and
  // settings above — the unpaid-drop-in payments, the pinned notes, the signed
  // avatars, and the force_committed audit row (one query for the whole roster,
  // never one per row). The audit's ACTOR, when there is one, is the single
  // genuine dependency left serial below.
  const [{ data: paidRows }, { data: pinned }, avatars, { data: fcAudit }] = await Promise.all([
    dropinIds.length
      ? supabase.from("payments").select("booking_id")
          .in("booking_id", dropinIds).in("status", ["succeeded", "partially_refunded"])
      : Promise.resolve({ data: [] as { booking_id: string | null }[] }),
    // notes_read withholds managers_only from front desk and instructors, so
    // this receives only what the caller may see.
    memberIds.length
      ? supabase.from("member_notes").select("member_id, category, body")
          .in("member_id", memberIds).eq("pinned", true).eq("active", true)
      : Promise.resolve({ data: [] as { member_id: string; category: string; body: string }[] }),
    signAvatars(supabase, (bookings ?? []).map((b) => b.members?.avatar_url)),
    forced
      ? supabase.from("audit_logs").select("actor_user_id, after, created_at")
          .eq("entity_id", occ.id).eq("action", "occurrence.force_committed")
          .order("created_at", { ascending: false }).limit(1).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);

  const paidBookings = new Set<string>();
  for (const p of paidRows ?? []) if (p.booking_id) paidBookings.add(p.booking_id as string);

  // The committed-to-run after-state: who forced it and why. The actor is
  // identified by their studio_staff email (the app keys staff by email), or the
  // viewer's own when it was them.
  let forcedBy: string | null = null;
  if (fcAudit) {
    const actorId = fcAudit.actor_user_id;
    if (actorId && actorId === ctx.userId) forcedBy = ctx.email;
    else if (actorId) {
      const { data: actor } = await supabase.from("studio_staff")
        .select("email").eq("studio_id", ctx.studioId).eq("user_id", actorId).maybeSingle();
      forcedBy = actor?.email ?? "a manager";
    } else forcedBy = "a manager";
  }
  const fcAfter = fcAudit?.after as { reason?: string; at?: string } | null | undefined;

  const nameOf = new Map((bookings ?? []).map((b) =>
    [b.member_id, `${b.members?.preferred_name || b.members?.first_name || ""} ${b.members?.last_name || ""}`.trim()]));

  const notesFor = new Map<string, { category: string; body: string }[]>();
  for (const n of pinned ?? []) {
    notesFor.set(n.member_id, [...(notesFor.get(n.member_id) ?? []), n]);
  }

  const checkedIn = new Set((checkIns ?? []).map((c) => c.booking_id));
  // Decision 35: how each person got checked in — self (with the distance),
  // scanned by the instructor, or at the desk.
  const checkinMeta = new Map((checkIns ?? [])
    .filter((c) => c.booking_id)
    .map((c) => [c.booking_id as string, { method: c.method as string, distance: c.distance_m as number | null }]));
  const methodLabel = (m?: { method: string; distance: number | null }) => {
    if (!m) return null;
    if (m.method === "self") return m.distance != null ? `Self · ${m.distance} m` : "Self check-in";
    if (m.method === "instructor") return "Scanned";
    return "Desk";
  };
  const booked = (bookings ?? []).filter((b) => ["booked", "attended", "no_show"].includes(b.status));
  const waitlisted = (bookings ?? []).filter((b) => b.status === "waitlisted");
  const inCount = booked.filter((b) => checkedIn.has(b.id) || b.status === "attended").length;

  const day = relativeDayName(occ.starts_at, ctx.timeZone) ?? fmtDayLong(occ.starts_at, ctx.timeZone);

  return (
    <AppShell
      {...shell}
      title={occ.name}
      actions={<NavLink href="/">Back to the dashboard</NavLink>}
    >
      {/* The facts of the class, as a line of text rather than a row of stat
          cards. Four numbers do not need four boxes. */}
      <p className="mb-5 text-[13px] leading-[20px] text-ink-2">
        {day} at <span className="num text-ink">{fmtTime(occ.starts_at, ctx.timeZone, ctx.timeFormat)}</span>
        {" · "}{occ.instructors?.display_name ?? "No instructor"}
        {occ.rooms?.name ? ` · ${occ.rooms.name}` : ""}
        {" · "}
        <span className="num text-ink">{occ.booked_count}/{occ.capacity}</span> booked
        {inCount > 0 && <>, <span className="num text-ink">{inCount}</span> checked in</>}
        {occ.status === "cancelled" && " · this class is cancelled"}
        {/* Decision 91: hidden from the member side (set on the Schedule popup). */}
        {occ.hidden_from_members && (
          <span className="ml-1 inline-flex items-center rounded-full border px-1.5 text-[11px] font-medium leading-[16px] align-middle"
                style={{ background: "var(--surface)", color: "var(--ink-2)", borderColor: "var(--line-2)" }}
                title="Hidden from members — still on your calendar">
            Hidden
          </span>
        )}
        {/* Decision 38: the assignment-confirmation state, when the class was asked. */}
        {occ.assignment_confirmed_at
          ? <span className="ml-1" style={{ color: "var(--lime-text)" }}> · confirmed ✓</span>
          : occ.assignment_requested_at
            ? <span className="ml-1 text-ink-3"> · awaiting confirmation</span>
            : null}
      </p>

      {/* Take the instructor off and open the shift — from the class itself.
          Manager-up, and only while there is somebody to remove on a live
          class. */}
      {isManagerUp(ctx.role) && occ.status === "scheduled" && occ.instructor_id && (
        <OpenShift occurrenceId={occ.id} instructorName={occ.instructors?.display_name ?? "the instructor"} />
      )}

      {/* The mirror: a class with nobody teaching it. Assign someone (through
          move_occurrence, the same validation a drag gets) or put it back out
          to instructors — so a gap can be filled without dragging it in day
          view, which was the only way and undiscoverable. */}
      {unstaffed && (
        <AssignShift occurrenceId={occ.id} candidates={candidates} pendingApplications={pendingApplications} />
      )}

      {/* Decision 47: cancel this class (or the rest of its weekday this month),
          manager-up and only while it is still scheduled. */}
      {isManagerUp(ctx.role) && occ.status === "scheduled" && (
        <CancelClass occurrenceId={occ.id}
          weekday={new Intl.DateTimeFormat("en-GB", { weekday: "long", timeZone: ctx.timeZone }).format(new Date(occ.starts_at))}
          hasInstructor={!!occ.instructor_id} bookedCount={occ.booked_count} />
      )}

      {/* Decision 22: make a below-minimum flex (or high-minimum core) class run.
          Once committed, the control is replaced by the confirmed-to-run line. */}
      {showRunAnyway && <RunAnyway occurrenceId={occ.id} minimum={runMinimum} />}
      {!showRunAnyway && forced && fcAfter && (
        <p className="mb-5 text-[13px] leading-[19px]" style={{ color: "var(--lime-text)" }}>
          Confirmed to run{fcAfter.reason ? ` · ${fcAfter.reason}` : ""}
          {forcedBy ? ` · by ${forcedBy}` : ""}
          {fcAfter.at ? ` at ${fmtTime(fcAfter.at, ctx.timeZone, ctx.timeFormat)}` : ""}
        </p>
      )}

      {heldPay && <ReleasePay occurrenceId={occ.id} />}

      {/* The desk end of the member's rotating code. Without it the QR on
          their phone is a picture nothing can read. */}
      <CodeCheckIn occurrenceId={occ.id} />

      <ToastHost />
      <SectionLabel>Roster</SectionLabel>
      {booked.length === 0 ? (
        <Empty>Nobody has booked yet. They will appear here as they do.</Empty>
      ) : (
        <Rows>
          {searchParams?.member && <ScrollToMember memberId={searchParams.member} />}
          {booked.map((b) => {
            const band = bandOf(b.members?.health_band);
            // Only the bands that ask something of you. A wall of "healthy"
            // chips would make the colour mean nothing, and the point of the
            // chip here is that front desk sees it while the member is
            // standing in front of them.
            const flag = band === "drifting" || band === "at_risk";
            // Decision 83: a Journey link arrives with ?member=… — that row is
            // given an id (so it can be scrolled to) and a persistent ring.
            const jumped = searchParams?.member === b.member_id;
            return (
              <div key={b.id}
                id={jumped ? `roster-member-${b.member_id}` : undefined}
                className={`scroll-mt-24 px-3 py-2.5${jumped ? " rounded-lg ring-1 ring-ink-3" : ""}`}>
                <div className="flex items-center justify-between gap-4">
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
                  {guestOf.has(b.member_id) && (
                    <span className="shrink-0 rounded-full px-2 py-0.5 text-[11px] font-semibold"
                          style={{ background: "var(--lime-tint)", color: "var(--lime-text)" }}>
                      {/* A host-null pass is a Decision 30 free first class — the
                          member booked their own, nobody brought them. */}
                      {guestOf.get(b.member_id) ? "Guest · first time" : "First class (free)"}
                    </span>
                  )}
                  {groupOf.has(b.member_id) && (
                    <span className="shrink-0 rounded-full px-2 py-0.5 text-[11px] font-semibold"
                          style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>
                      {/* Decision 76: a group (Barkada) seat. */}
                      {groupOf.get(b.member_id)!.isHost
                        ? `${groupOf.get(b.member_id)!.plan} · host`
                        : groupOf.get(b.member_id)!.plan}
                    </span>
                  )}
                  <span className="hidden truncate text-[12px] leading-4 text-ink-3 sm:block">
                    {b.payment_source?.replace("_", " ") ?? "—"}
                    {b.override_reason ? ` · override: ${b.override_reason}` : ""}
                    {checkedIn.has(b.id) && methodLabel(checkinMeta.get(b.id)) ? ` · ${methodLabel(checkinMeta.get(b.id))}` : ""}
                  </span>
                </div>
                <CheckInButton
                  bookingId={b.id}
                  memberId={b.member_id}
                  occurrenceId={occ.id}
                  alreadyIn={checkedIn.has(b.id) || b.status === "attended"}
                />
                </div>
                {/* Under the name, not beside it: an instructor reading the
                    roster before a class is reading down the list, and a note
                    about a shoulder has to be in the column their eye is
                    already in. */}
                {guestOf.get(b.member_id) && (
                  <p className="mt-1 pl-9 text-[12px] leading-[18px] text-ink-2">
                    Brought by {nameOf.get(guestOf.get(b.member_id) ?? "") || "a member"}
                  </p>
                )}
                {groupOf.has(b.member_id) && !groupOf.get(b.member_id)!.isHost && (
                  <p className="mt-1 pl-9 text-[12px] leading-[18px] text-ink-2">
                    Booked by {groupOf.get(b.member_id)!.host}
                  </p>
                )}
                {desk && b.members?.phone && (
                  <p className="mt-1 pl-9 text-[12px] leading-[18px] text-ink-2">
                    <a href={`tel:${b.members.phone}`} className="text-ink underline decoration-line-2 underline-offset-2 hover:decoration-ink">{formatPhone(b.members.phone)}</a>
                    {" · "}
                    <a href={`sms:${b.members.phone}`} className="text-ink underline decoration-line-2 underline-offset-2 hover:decoration-ink">Text</a>
                  </p>
                )}
                {guestOf.has(b.member_id) && !b.members?.waiver_signed_at && (
                  <PaperWaiverButton memberId={b.member_id} occurrenceId={occ.id} />
                )}
                {manager && b.status === "booked" && b.payment_source === "drop_in" && !paidBookings.has(b.id) && (
                  <MakeFreeButton bookingId={b.id} occurrenceId={occ.id} />
                )}
                {/* Decision 92: rebook this member into another class (all staff). */}
                {occ.status === "scheduled" && (b.status === "booked" || b.status === "attended") && (
                  <RebookButton bookingId={b.id} timeZone={ctx.timeZone} timeFormat={ctx.timeFormat} />
                )}
                {(notesFor.get(b.member_id) ?? []).map((n, i) => (
                  <p key={i} className="mt-1 pl-9 text-[12px] leading-[18px]"
                     style={{ color: n.category === "injury" || n.category === "medical"
                              ? "var(--coral-deep)" : "var(--ink-2)" }}>
                    {n.category === "injury" || n.category === "medical" ? "\u26a0 " : ""}
                    {n.body}
                  </p>
                ))}
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
