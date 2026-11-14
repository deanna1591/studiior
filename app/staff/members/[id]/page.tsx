import Link from "next/link";
import { notFound } from "next/navigation";
import { isDeskUp, isManagerUp } from "@/lib/auth";
import Infractions from "./infractions";
import DeskPay from "./desk-pay";
import ReservationFeeWaiver from "./reservation-fee-waiver";
import { staffScreen } from "@/lib/screen";
import { AppShell, Empty, NavLink, Rows, SectionLabel } from "@/components/ui";
import { InviteOne } from "../invites/panel";
import { HealthBand, bandOf } from "@/components/health-band";
import { MessageLink } from "@/components/message-link";
import InviteToApp from "@/components/invite-to-app";
import { formatMoney } from "@/lib/plans";
import { formatPhone } from "@/lib/phone";
import { dayMonthParts, dayMonthLongParts, fmtTime } from "@/lib/time";
import { studioToday } from "@/lib/dashboard";
import MembershipActions from "./membership-actions-panel";
import GrantComplimentary from "./grant-complimentary";
import { StateChip } from "@/components/state-chip";
import { TimelineList } from "./timeline";
import NotesPanel from "./records/notes";
import GoalsPanel from "./records/goals";
import DocumentsPanel, { PhotoUpload } from "./records/documents";
import { AttendancePattern } from "./attendance";
import { ResendGuestInvite } from "./resend-guest";
import MemberDangerZone from "./danger";
import EditPhone from "@/components/staff/edit-phone";
import { BookClassFromProfile } from "@/components/staff/book-member";
import ToastHost from "@/components/staff/toast-host";
import { fullName } from "@/lib/full-name";

export const dynamic = "force-dynamic";

// A year of a twice-weekly member is well over a hundred entries. Showing the
// lot pushes everything else off the page for the one member most likely to be
// worth reading about.
const JOURNEY_SHOWN = 14;

/**
 * One member, per Bible 6.2–6.12 and data model §4.
 *
 * The health band is the first thing on the page, full width, with its reason
 * as a whole sentence — this is the screen it was designed for, and everything
 * under it is the evidence behind it.
 *
 * Nothing here filters by role in TypeScript. The notes query asks for every
 * note and gets back only the ones this caller may read, because notes_read is
 * `is_manager_up(studio_id) or not managers_only` — so front desk is not shown
 * a member's medical history by the database, not by this file remembering to
 * leave it out. The one exception is payments, and it is called out below.
 */
export default async function MemberDetail({
  params, searchParams,
}: {
  params: { id: string };
  searchParams: { sent?: string; recorded?: string };
}) {
  const screen = await staffScreen("/members");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  const { data: m } = await supabase
    .from("members")
    .select("id, first_name, last_name, email, phone, status, joined_on, source, waiver_signed_at, first_visit_at, last_visit_at, lifetime_visits, current_streak, health_band, health_reason, user_id, avatar_url, desk_pay_blocked_at, desk_pay_blocked_reason, deleted_at, merged_into, reservation_fee_waived_at, reservation_fee_waived_note")
    .eq("id", params.id)
    .maybeSingle();
  if (!m) notFound();

  const manager = isManagerUp(ctx.role);
  // Decision 103a: the "No reservation fee" switch is shown only when the studio
  // charges a reservation fee (otherwise it is moot).
  const { data: feeSetting } = manager
    ? await supabase.from("studio_settings").select("free_first_reservation_fee_cents").eq("studio_id", ctx.studioId).maybeSingle()
    : { data: null };
  const studioChargesReservationFee = (feeSetting?.free_first_reservation_fee_cents ?? 0) > 0;
  // §9 gives front desk payments, so the desk gets the button that takes one.
  const desk = isDeskUp(ctx.role);

  const [
    { data: memberships }, { data: ledger }, { data: visits },
    { data: activity }, { data: notes }, { data: goals }, { data: tags },
    { data: docs }, { data: standing }, { data: infractions },
    { data: guestPass }, { data: lastInvite },
  ] = await Promise.all([
    supabase.from("memberships")
      .select("id, plan_id, status, price_cents, currency, starts_on, expires_on, renews_on, credits_remaining, auto_renew, freeze_end, complimentary, membership_plans(name, type)")
      .eq("member_id", params.id).order("starts_on", { ascending: false }),
    supabase.from("credit_ledger")
      .select("id, delta, reason, balance_after, created_at")
      .eq("member_id", params.id).order("created_at", { ascending: false }).limit(12),
    supabase.from("check_ins")
      .select("id, checked_in_at")
      .eq("member_id", params.id).order("checked_in_at", { ascending: false }).limit(600),
    // Decision 75a: the journey reads the member_activity statement (bookings,
    // check-ins, credit movements, payments, occurrence events, joined and
    // message_sent for staff). timeline_events and its triggers stay in place
    // until parity is proven in a follow-up.
    supabase.rpc("member_activity", { p_member_id: params.id, p_from: "2000-01-01", p_to: "2100-01-01" }),
    supabase.from("member_notes")
      .select("id, category, body, pinned, managers_only, active, created_at")
      .eq("member_id", params.id).order("pinned", { ascending: false }).order("created_at", { ascending: false }),
    supabase.from("member_goals")
      .select("id, title, target_type, target_value, current_value, target_date, status, completed_at, created_at")
      .eq("member_id", params.id).order("status").order("target_date", { nullsFirst: false }),
    supabase.from("member_tag_assignments")
      .select("tag_id, member_tags(name)").eq("member_id", params.id),
    // The medical narrowing lives in the policy, so an instructor or a front
    // desk simply receives fewer rows here rather than this screen filtering.
    supabase.from("member_documents")
      .select("id, kind, filename, storage_path, size_bytes, signed_at, created_at")
      .eq("member_id", params.id).order("created_at", { ascending: false }),
    // Decision 24. `member_suspension()` answers NULL for a studio not using
    // suspension, so the whole section is absent there rather than drawn empty.
    supabase.rpc("member_suspension", { p_member_id: params.id }),
    supabase.from("member_infractions")
      .select("id, kind, occurred_at, status, voided_reason, class_occurrences(name)")
      .eq("member_id", params.id).order("occurred_at", { ascending: false }).limit(20),
    // Decision 26(b): if this member was brought in as a guest (host not null),
    // the App account panel tells the story and offers "Resend invite". The
    // host's first name comes from the guest pass; the invite date/expiry from
    // the member's latest invite.
    supabase.from("guest_passes")
      .select("host_member_id, created_at, invited_at, host_name_at_invite, members!host_member_id(first_name, deleted_at, merged_into)")
      .eq("guest_member_id", params.id).not("host_member_id", "is", null)
      .order("created_at", { ascending: false }).limit(1).maybeSingle(),
    supabase.from("member_invites")
      .select("expires_at, created_at, accepted_at")
      .eq("member_id", params.id).order("created_at", { ascending: false }).limit(1).maybeSingle()
  ]);

  // Payments are the one thing on this screen decided here rather than by the
  // database, and the decision has to be made twice — once for the section and
  // once for the journey, which carries `payment` events with their amounts and
  // is readable by every member of staff under timeline_staff_read. Hiding the
  // section while leaving "Paid CZK 1,800.00" two inches above it would be
  // worse than showing both.
  //
  // Permissions §9 note 18 gives front desk exactly this view — individual
  // transactions, to answer a member's question — and payments_desk_read
  // implements it, so front desk can still read these rows through the API.
  // Withholding them here is a display choice, not a boundary; if it should be
  // a boundary the policy has to change.
  const { data: payments } = manager
    ? await supabase.from("payments")
        .select("id, amount_cents, currency, status, description, card_brand, card_last4, paid_at, created_at, failure_message, provider, method, method_note, reference, refunded_cents")
        .eq("member_id", params.id).order("created_at", { ascending: false }).limit(20)
    : { data: null };

  // Decision 75a: the journey reads member_activity. Decision 83: carry the ids,
  // the running balance and plan_name / due_cents / is_free_first through so
  // TimelineList can link each row (class rows to the roster, money rows to the
  // membership/payment panel), show the balance, and say in plain words what
  // happened (moneyLine). Non-managers keep the display choice — the pure money
  // rows are withheld (class rows that merely carry a credit delta stay).
  const MONEY_KINDS = new Set(["purchase", "refund", "payment_failed", "credits_added", "credit_adjustment"]);
  type Act = { at: string; kind: string; title: string; detail: string | null;
    credit_delta: number | null; balance_after: number | null;
    amount_cents: number | null; currency: string | null;
    occurrence_id: string | null; booking_id: string | null; membership_id: string | null;
    plan_name: string | null; due_cents: number | null; is_free_first: boolean | null;
    occurrence_start: string | null; instructor_first: string | null;
    credits_left_after: number | null; payment_method: string | null;
    recorded_by_name: string | null; plan_classes: number | null;
    plan_valid_to: string | null; unused_credits: number | null;
    payment_source: string | null; is_paid: boolean | null };
  const journey = ((activity ?? []) as Act[])
    .filter((e) => manager || !MONEY_KINDS.has(e.kind))
    .map((e, i) => ({
      id: `${e.kind}:${e.occurrence_id ?? e.booking_id ?? e.membership_id ?? "x"}:${e.at}:${i}`,
      ...e,
    }));

  // Goal progress is computed, never read off member_goals.current_value —
  // that column has never been written and every goal read "0 of 12".
  //
  // Speed pass (1 Nov): this was one member_goal_progress RPC PER GOAL (an N+1
  // in its own serial wave). That function's class_count branch is just a
  // date-bounded count of check_ins from when the goal was set — and this page
  // already fetched `visits` (the member's check-ins). So mirror it in JS over
  // the rows in hand: the same UTC ::date comparison the SQL uses, no RPC, no
  // new query, no new wave. `visits` is the 600 most-recent check-ins, which
  // covers any goal window (counted from the goal's recent created_at) by a
  // wide margin.
  const visitDateKeys = (visits ?? []).map((v) => new Date(v.checked_in_at).toISOString().slice(0, 10));
  const goalRows = (goals ?? []).map((g) => {
    if (g.target_type === "class_count") {
      const fromKey = new Date(g.created_at as string).toISOString().slice(0, 10);
      const done = visitDateKeys.filter((dk) =>
        dk >= fromKey && (g.target_date == null || dk <= (g.target_date as string))).length;
      return { ...g, done, met: g.target_value != null && done >= g.target_value };
    }
    // Any other target type keeps the RPC's non-count reading exactly.
    return { ...g, done: g.current_value ?? 0, met: g.completed_at != null };
  });

  // Signed on render and short-lived. A URL stored in the column would outlive
  // its signature; the column holds the object PATH.
  const docRows = await Promise.all((docs ?? []).map(async (d) => {
    const { data } = await supabase.storage.from("member-documents")
      .createSignedUrl(d.storage_path, 300);
    return { ...d, url: data?.signedUrl ?? null };
  }));
  const photo = m.avatar_url
    ? (await supabase.storage.from("member-avatars")
        .createSignedUrl(m.avatar_url, 300)).data?.signedUrl ?? null
    : null;

  // Decision 61: active plans a manager can grant complimentary (incl. staff-only).
  const { data: grantablePlans } = manager
    ? await supabase.from("membership_plans").select("id, name, type")
        .eq("studio_id", ctx.studioId).eq("status", "active").order("name")
    : { data: [] as { id: string; name: string; type: string }[] };

  const live = (memberships ?? []).find(
    (x) => !["cancelled", "expired"].includes(x.status));
  const past = (memberships ?? []).filter((x) => x.id !== live?.id);

  const d = (iso: string) => {
    const { day, month } = dayMonthParts(iso, ctx.timeZone);
    return <><span className="num">{day}</span> {month}</>;
  };
  // Decision 26(b): the App account panel writes the date out in full ("3
  // November"), the plain written form the rest of the app uses for a single
  // moment; the page's other meta stays the compact "3 Nov" via d().
  const dLong = (iso: string) => {
    const { day, month } = dayMonthLongParts(iso, ctx.timeZone);
    return <><span className="num">{day}</span> {month}</>;
  };

  // Decision 26(b) / 97: a guest/friend brought by a host. The host name is the
  // invite SNAPSHOT (host_name_at_invite), so it survives the host being deleted
  // or merged; when the host account is since gone we say so.
  const gp = guestPass as {
    host_name_at_invite?: string | null; created_at?: string | null; invited_at?: string | null;
    members?: { first_name: string | null; deleted_at: string | null; merged_into: string | null } | null;
  } | null;
  const host = gp?.host_name_at_invite ?? gp?.members?.first_name ?? null;
  const hostGone = !!gp?.members && (!!gp.members.deleted_at || !!gp.members.merged_into);
  const invExpIso = (lastInvite as { expires_at?: string | null } | null)?.expires_at ?? null;
  const invMadeIso = (lastInvite as { created_at?: string | null } | null)?.created_at
    ?? gp?.invited_at ?? gp?.created_at ?? null;
  const invAcceptedIso = (lastInvite as { accepted_at?: string | null } | null)?.accepted_at ?? null;
  const isGuestBrought = !!host && !!invExpIso;
  const inviteExpired = invExpIso ? new Date(invExpIso).getTime() <= Date.now() : false;

  // Decision 97: a merged-away or deleted member is read-only, with a line
  // naming where they went. The kept member's name is a single lookup.
  const mm = m as typeof m & { deleted_at: string | null; merged_into: string | null };
  let mergedIntoName: string | null = null;
  if (mm.merged_into) {
    const { data: keep } = await supabase.from("members")
      .select("first_name, last_name").eq("id", mm.merged_into).maybeSingle();
    mergedIntoName = keep ? fullName(keep.first_name, keep.last_name) : null;
  }

  // Decision 98: same-person duplicates (chip + preselected merge) and the
  // Decision 97(a) merge-trace lines (merges INTO this member). Both desk-up
  // readers; fetched only for a live member a manager is looking at.
  let dupes: { id: string; first_name: string; last_name: string; email: string; had_free: boolean }[] = [];
  let mergeTrace: { removed_first: string | null; removed_last: string | null; removed_email: string | null; at: string; staff_first: string }[] = [];
  if (!mm.deleted_at) {
    const [{ data: d }, { data: tr }] = await Promise.all([
      manager ? supabase.rpc("member_duplicates", { p_member_id: params.id }) : Promise.resolve({ data: [] }),
      supabase.rpc("member_merge_trace", { p_member_id: params.id }),
    ]);
    dupes = (d as typeof dupes) ?? [];
    mergeTrace = (tr as typeof mergeTrace) ?? [];
  }
  const suggested = dupes[0] ?? null;

  return (
    <AppShell
      {...shell}
      title={fullName(m.first_name, m.last_name)}
      actions={
        <>
          {/* Front desk sells (§9) but cannot see the Payments section below,
              which is manager-only by display choice — so their way in is here
              rather than buried in a section they never see. */}
          {isDeskUp(ctx.role) && (
            <NavLink href={`/members/${params.id}/payment`}>Record a payment</NavLink>
          )}
          <NavLink href="/members">Back to members</NavLink>
        </>
      }
    >
      {/* Decision 97: a deleted or merged member is read-only. */}
      {mm.deleted_at && (
        <section className="mb-6 border-l-[3px] px-3 py-2.5"
          style={{ borderLeftColor: "var(--ink-2)", background: "var(--paper)" }}>
          <p className="text-[13px] leading-[19px] text-ink">
            {mm.merged_into
              ? <>Merged into {mergedIntoName ?? "another member"} on {dLong(mm.deleted_at)}.</>
              : <>Deleted on {dLong(mm.deleted_at)}. Their history is kept.</>}
          </p>
        </section>
      )}

      {/* Decision 97(a): a trace of every merge INTO this member — the removed
          names and email survive the scrub, read from the audit rows. */}
      {mergeTrace.length > 0 && (
        <section className="mb-6 border-l-[3px] px-3 py-2.5"
          style={{ borderLeftColor: "var(--ink-2)", background: "var(--paper)" }}>
          {mergeTrace.map((t, i) => (
            <p key={i} className="text-[13px] leading-[19px] text-ink-2">
              Merged from {t.removed_first} {t.removed_last}
              {t.removed_email ? ` (${t.removed_email})` : ""} on {dLong(t.at)} by {t.staff_first}.
            </p>
          ))}
        </section>
      )}

      {/* Decision 98: a same-person match — the "Possible duplicate" chip opens
          the Decision 97 merge with both sides preselected (in the Danger zone). */}
      {manager && !mm.deleted_at && suggested && (
        <a href="#danger"
          className="mb-6 inline-flex items-center gap-2 rounded-full border px-3 py-1 text-[12.5px] font-medium"
          style={{ borderColor: "var(--amber-deep)", color: "var(--ink)", background: "var(--amber-tint)" }}>
          Possible duplicate: {suggested.first_name} {suggested.last_name}
          {suggested.had_free ? " (has had a free class)" : ""} &middot; review &amp; merge
        </a>
      )}

      {/* An account, or the way to offer one. Not buried in a section: for a
          member who has never been invited this is the single most useful thing
          on the screen, and until now the only way to send one was for an
          operator to copy a link out of a database. */}
      {isDeskUp(ctx.role) && !m.user_id && !mm.deleted_at && (
        <section className="mb-6 rounded-xl border border-line bg-surface px-3.5 py-3">
          <SectionLabel>App account</SectionLabel>
          {isGuestBrought ? (
            // Decision 26(b): brought in as a guest, not yet claimed — tell the
            // story and offer the resend (the guest_invite email, not member_invite).
            <>
              <p className="mb-2.5 mt-1 max-w-[58ch] text-[13px] leading-[19px] text-ink-2">
                {inviteExpired
                  ? <>{m.first_name}&rsquo;s link expired on {dLong(invExpIso!)}.</>
                  : <>{m.first_name} was invited by {host}{hostGone && " (account deleted)"} on {dLong(invMadeIso!)}. Their link to set
                      a password and sign the waiver is open until {dLong(invExpIso!)}.</>}
              </p>
              <ResendGuestInvite memberId={params.id}
                label={inviteExpired ? "Send a new invite" : "Resend invite"} />
            </>
          ) : (
            // Members staff added by hand keep today's wording.
            <>
              <p className="mb-2.5 mt-1 max-w-[58ch] text-[13px] leading-[19px] text-ink-2">
                {m.email
                  ? <>{m.first_name} cannot sign in yet. An invite emails them a link to set a
                      password — from {ctx.studioName}, with nothing to download.</>
                  : <>{m.first_name} has no email address, so there is nowhere to send an
                      invite. Add one to their record first.</>}
              </p>
              {m.email && <InviteOne memberId={params.id} />}
            </>
          )}
        </section>
      )}
      {searchParams.recorded && (
        <p className="mb-4 border-l-[3px] px-3 py-2 text-[13px] leading-[18px] text-ink"
           style={{ borderLeftColor: "var(--lime-text)", background: "var(--lime-tint)" }}>
          Payment recorded.
        </p>
      )}
      {searchParams.sent && (
        <p className="mb-4 border-l-[3px] px-3 py-2 text-[13px] leading-[18px] text-ink"
           style={{ borderLeftColor: "var(--lime-text)", background: "var(--lime-tint)" }}>
          Queued. It will go out on the next send — nothing has left yet, and it
          is on {m.first_name}&rsquo;s journey below.
        </p>
      )}
      {/* The photograph, beside the person it belongs to. avatar_url has
          existed since migration 035 and this screen never rendered it — and
          only the member could upload one, which is no use for the walk-in
          signing up at the desk. */}
      <div className="mb-4">
        {isDeskUp(ctx.role)
          ? <PhotoUpload memberId={m.id} name={fullName(m.first_name, m.last_name)} url={photo} />
          : photo && (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={photo} alt="" aria-hidden className="h-16 w-16 rounded-full object-cover" />
          )}
      </div>
      <p className="mb-1 text-[13px] leading-[20px] text-ink-2">
        {m.email}
        {m.phone && (
          <>
            {" · "}
            <a href={`tel:${m.phone}`} className="text-ink underline-offset-2 hover:underline">{formatPhone(m.phone)}</a>
            {" · "}
            <a href={`sms:${m.phone}`} className="text-ink underline-offset-2 hover:underline">Text</a>
          </>
        )}
        {" · joined "}{d(m.joined_on)}
        {m.status !== "active" && <> · {m.status}</>}
        {!m.waiver_signed_at && <> · <span className="text-ink">no waiver signed</span></>}
      </p>
      <ToastHost />
      {/* Decision 100: the desk edits the phone and books a class for them. */}
      {isDeskUp(ctx.role) && !mm.deleted_at && (
        <div className="mb-4 flex flex-wrap items-center gap-3">
          <EditPhone memberId={m.id} current={m.phone} />
          <BookClassFromProfile memberId={m.id} />
        </div>
      )}
      {/* Whether they can actually use the app they are being messaged about. */}
      <div className="mb-4 mt-2">
        {m.user_id ? (
          // Decision 26(b): once claimed, the account's own line.
          <p className="text-[12px] leading-4 text-ink-3">
            Signed in since {dLong(invAcceptedIso ?? m.joined_on)}.
          </p>
        ) : isDeskUp(ctx.role) ? (
          <InviteToApp memberId={m.id} />
        ) : (
          <p className="text-[12px] leading-4 text-ink-3">No account yet.</p>
        )}
      </div>

      {(tags ?? []).length > 0 && (
        <p className="mb-4 flex flex-wrap gap-1.5">
          {(tags ?? []).map((t) => (
            <span key={t.tag_id}
                  className="rounded-full border border-line-2 px-2 py-0.5 text-[11px] leading-4 text-ink-2">
              {t.member_tags?.name}
            </span>
          ))}
        </p>
      )}

      {/* The band, first and full width, with the one thing you would do about
          it beside it. */}
      <div className="mb-8 mt-4 flex flex-col gap-3 sm:flex-row sm:items-start">
        <div className="min-w-0 flex-1">
          <HealthBand band={bandOf(m.health_band)} reason={m.health_reason} size="hero" />
        </div>
        {isDeskUp(ctx.role) && (
          <MessageLink href={`/members/${m.id}/message`} className="shrink-0 sm:mt-1" />
        )}
      </div>

      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_340px]">
        {/* ---------- the narrative ---------- */}
        <div className="space-y-5">
          <section className="s-card p-5">
            <h2 className="s-head mb-3">Attendance</h2>
            <p className="mb-3 text-[13px] leading-[20px] text-ink-2">
              <span className="num text-ink">{m.lifetime_visits}</span> visit
              {m.lifetime_visits === 1 ? "" : "s"} in all
              {m.current_streak > 0 && <> · <span className="num text-ink">{m.current_streak}</span> week streak</>}
              {m.first_visit_at && <> · first came {d(m.first_visit_at)}</>}
              {m.last_visit_at && <> · last {d(m.last_visit_at)}</>}
            </p>
            {(visits ?? []).length === 0 ? (
              <Empty>No visits yet. They are on the books but have not been through the door.</Empty>
            ) : (
              <AttendancePattern visits={visits ?? []} timeZone={ctx.timeZone} />
            )}
          </section>

          <section className="s-card p-5">
            <h2 className="s-head mb-3">Journey</h2>
            {journey.length === 0 ? (
              <Empty>Nothing recorded yet. Their first visit will start this off.</Empty>
            ) : (
              <>
                <TimelineList events={journey.slice(0, JOURNEY_SHOWN)} timeZone={ctx.timeZone} timeFormat={ctx.timeFormat} memberId={params.id} manager={manager} currency={ctx.currency} />
                {journey.length > JOURNEY_SHOWN && (
                  <p className="mt-3 text-[12px] leading-4 text-ink-3">
                    <span className="num">{journey.length - JOURNEY_SHOWN}</span> earlier
                    {" "}entries not shown.
                  </p>
                )}
              </>
            )}
          </section>

          {manager && (
            <section id="payments" className="s-card scroll-mt-4 p-5">
              <div className="mb-3 flex items-baseline justify-between gap-3">
                <h2 className="s-head">Payments</h2>
                <NavLink href={`/members/${params.id}/payment`}>Record a payment</NavLink>
              </div>
              {(payments ?? []).length === 0 ? (
                <Empty>
                  Nothing recorded yet.{" "}
                  <NavLink href={`/members/${params.id}/payment`}>Record a payment</NavLink>
                </Empty>
              ) : (
                <Rows>
                  {(payments ?? []).map((p) => (
                    <div key={p.id} className="flex items-start justify-between gap-4 px-3 py-2">
                      <span className="min-w-0">
                        <span className="block truncate text-[13px] leading-[18px] text-ink">
                          {p.description ?? "Payment"}
                        </span>
                        <span className="block text-[11px] leading-4 text-ink-3">
                          {d(p.paid_at ?? p.created_at)}
                          {/* How the money arrived, which is the whole point of
                              recording it: this is what the studio reconciles
                              against their own books. */}
                          {p.provider === "manual" && p.method && (
                            <> · {p.method.replace("_", " ")}
                              {p.method_note ? ` (${p.method_note})` : ""}</>
                          )}
                          {p.card_brand && <> · {p.card_brand} ····{p.card_last4}</>}
                          {p.provider === "xendit" && <> · Xendit</>}
                          {p.reference && <> · ref {p.reference}</>}
                          {p.status !== "succeeded" && <> · {p.status.replace("_", " ")}</>}
                          {p.refunded_cents > 0 && p.status === "partially_refunded" && (
                            <> · {formatMoney(p.refunded_cents, p.currency)} back</>
                          )}
                        </span>
                        {p.failure_message && (
                          <span className="mt-0.5 block text-[11px] leading-4 text-ink">
                            {p.failure_message}
                          </span>
                        )}
                      </span>
                      <span className={`num shrink-0 text-[13px] ${
                        p.status === "succeeded" ? "text-ink" : "text-ink-3 line-through"}`}>
                        {formatMoney(p.amount_cents, p.currency)}
                      </span>
                    </div>
                  ))}
                </Rows>
              )}
            </section>
          )}
        </div>

        {/* ---------- the facts ---------- */}
        <div className="space-y-8">
          <section id="membership" className="s-card scroll-mt-4 p-5">
            <h2 className="s-head mb-3">Membership</h2>
            {!live ? (
              <Empty quiet>
                Nothing active.{" "}
                {manager ? "Sell them a plan to get them booking." : "An owner or manager can sell them one."}
              </Empty>
            ) : (
              <div className="rounded-xl px-3 py-2.5" style={{ background: "var(--paper)" }}>
                <div className="flex items-center gap-2 text-[14px] leading-5 text-ink">
                  {live.membership_plans?.name}
                  {live.complimentary && <StateChip state="complimentary" />}
                </div>
                <div className="mt-0.5 text-[12px] leading-4 text-ink-3">
                  {/* Decision 61: a complimentary membership has no price. */}
                  {live.complimentary
                    ? <>Complimentary</>
                    : <span className="num">{formatMoney(live.price_cents, live.currency)}</span>}
                  {" · "}{live.status.replace("_", " ")}
                  {live.renews_on && <> · renews {d(live.renews_on)}</>}
                  {live.expires_on && <> · {live.complimentary ? "until" : "expires"} {d(live.expires_on)}</>}
                  {!live.auto_renew && !live.complimentary && live.membership_plans?.type !== "recurring" && <> · will not renew</>}
                </div>
                {/* Decision 66: a recurring membership bought online is one period
                    at a time — the member renews by hand. */}
                {live.membership_plans?.type === "recurring" && !live.auto_renew && !live.complimentary && (
                  <div className="mt-1 text-[12px] leading-4 text-ink-3">
                    Online · one period at a time{live.renews_on && <> · ends {d(live.renews_on)}</>}
                  </div>
                )}
                <div className="mt-2 text-[13px] leading-[18px] text-ink">
                  {live.membership_plans?.type === "recurring" && live.credits_remaining === null
                    ? "Unlimited classes"
                    : <><span className="num">{live.credits_remaining ?? 0}</span> credit
                        {live.credits_remaining === 1 ? "" : "s"} left</>}
                </div>
                {/* MONEY OWED IS NOT A WORD IN A METADATA LINE. `past_due` was
                    rendering as "past due" in --ink-3 between the price and the
                    renewal date, which is where an eye slides past it. The desk
                    needs the fact and the one button that fixes it. */}
                {live.status === "past_due" && (
                  <div className="mt-2.5 rounded-lg border-l-[3px] px-2.5 py-2"
                       style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}>
                    <p className="text-[13px] leading-[19px] text-ink">
                      This membership is not paid up
                      {live.renews_on && <> — it was due on {d(live.renews_on)}</>}.
                    </p>
                    {desk && (
                      <Link
                        href={`/members/${params.id}/payment?plan=${live.plan_id ?? ""}`}
                        className="mt-1 inline-block text-[12px] font-medium leading-4 text-lime-text underline underline-offset-4 hover:text-lime-text2"
                      >
                        Record a payment
                      </Link>
                    )}
                  </div>
                )}
              </div>
            )}
            {/* Decision 49: the five membership actions, manager-up. Front desk
                sees the membership but no controls (the RPCs refuse them anyway).
                Past memberships stay read-only. */}
            {manager && live && (
              <MembershipActions
                membershipId={live.id}
                frozen={live.status === "frozen"}
                frozenUntil={live.freeze_end}
                priceCents={live.price_cents}
                currency={live.currency}
                expiresOn={live.expires_on}
                today={studioToday(ctx.timeZone)}
                complimentary={!!live.complimentary}
              />
            )}
            {/* Decision 61: grant a free, ongoing membership. Manager-up; works
                whether or not they already have a (different) plan. */}
            {manager && (
              <GrantComplimentary memberId={params.id} plans={grantablePlans ?? []} />
            )}
            {past.length > 0 && (
              <p className="mt-2 text-[11px] leading-4 text-ink-3">
                {past.length} earlier membership{past.length === 1 ? "" : "s"}, kept at the price
                {past.length === 1 ? " it was" : " they were"} bought at.
              </p>
            )}
          </section>

          <section className="s-card p-5">
            <h2 className="s-head mb-3">Credits</h2>
            {(ledger ?? []).length === 0 ? (
              <Empty quiet>No credit movements yet.</Empty>
            ) : (
              <>
                <div className="flex justify-end gap-3 pb-1 pr-3 text-[10px] uppercase leading-4 tracking-[0.06em] text-ink-3">
                  <span>Change</span><span>Left</span>
                </div>
              <Rows>
                {(ledger ?? []).map((c) => (
                  <div key={c.id} className="flex items-baseline justify-between gap-3 px-3 py-1.5">
                    <span className="min-w-0 truncate text-[12px] leading-4 text-ink-2">
                      {c.reason.replace(/_/g, " ")}
                      <span className="ml-1.5 text-ink-3">{d(c.created_at)}</span>
                    </span>
                    <span className="num shrink-0 text-[12px] text-ink">
                      {c.delta > 0 ? `+${c.delta}` : c.delta}
                      <span className="ml-1.5 text-ink-3">{c.balance_after}</span>
                    </span>
                  </div>
                ))}
              </Rows>
              </>
            )}
            <p className="mt-2 text-[11px] leading-4 text-ink-3">
              The balance is the ledger added up, never edited directly.
            </p>
          </section>

          {/* Notes, goals and documents are now WRITTEN here rather than
              listed. All three tables have existed since migration 001 (or, for
              documents, only in Chapter 6's scope) with nothing in the product
              putting a row in them. */}
          <NotesPanel memberId={m.id} notes={notes ?? []} canSeeManagerOnly={manager} />

          <GoalsPanel memberId={m.id} goals={goalRows} />

          <DocumentsPanel memberId={m.id} docs={docRows}
                          waiverSignedAt={m.waiver_signed_at} canDelete={manager} />
        </div>
      </div>
      {manager && m.desk_pay_blocked_at && (
        <DeskPay memberId={m.id} since={m.desk_pay_blocked_at}
                 reason={m.desk_pay_blocked_reason as "no_show" | "late_cancel" | null} />
      )}
      {manager && studioChargesReservationFee && !m.deleted_at && (
        <ReservationFeeWaiver memberId={m.id}
          waived={m.reservation_fee_waived_at != null}
          since={m.reservation_fee_waived_at as string | null}
          note={m.reservation_fee_waived_note as string | null} />
      )}
      <Infractions
        standing={
          standing
            ? {
                count: (standing as Record<string, number>).count,
                warned: (standing as unknown as { warned: boolean }).warned,
                suspended: (standing as unknown as { suspended: boolean }).suspended,
                until: (standing as unknown as { until: string | null }).until,
                // Formatted on the server: a formatter crossing into a client
                // component is a runtime error TypeScript will not warn about.
                untilLabel: (standing as unknown as { until: string | null }).until
                  ? new Intl.DateTimeFormat("en-GB", {
                      weekday: "long", day: "numeric", month: "long",
                      timeZone: ctx.timeZone,
                    }).format(new Date((standing as unknown as { until: string }).until))
                  : null,
                window_days: (standing as Record<string, number>).window_days,
                suspend_at: (standing as Record<string, number>).suspend_at,
                until_suspension: (standing as Record<string, number | null>).until_suspension,
              }
            : null
        }
        rows={(infractions ?? []).map((r: {
          id: string; kind: string; occurred_at: string; status: string;
          voided_reason: string | null; class_occurrences: { name: string } | null;
        }) => ({
          id: r.id, kind: r.kind, occurred_at: r.occurred_at,
          occurredLabel: new Intl.DateTimeFormat("en-GB", {
            day: "numeric", month: "short", timeZone: ctx.timeZone,
          }).format(new Date(r.occurred_at)) + " " + fmtTime(r.occurred_at, ctx.timeZone, ctx.timeFormat),
          className: r.class_occurrences?.name ?? null,
          status: r.status,
          voided_reason: r.voided_reason,
        }))}
      />

      {/* Decision 97: merge a duplicate or delete the member. Manager-up, and
          never on an already-deleted/merged member. The database refuses a
          staff or instructor login with a clear message. */}
      {manager && !mm.deleted_at && (
        <MemberDangerZone memberId={params.id} firstName={m.first_name} studioId={ctx.studioId}
          suggested={suggested ? { id: suggested.id, name: fullName(suggested.first_name, suggested.last_name), email: suggested.email } : null} />
      )}
    </AppShell>
  );
}
