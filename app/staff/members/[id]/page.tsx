import Link from "next/link";
import { notFound } from "next/navigation";
import { isDeskUp, isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Empty, NavLink, Rows, SectionLabel } from "@/components/ui";
import { InviteOne } from "../invites/panel";
import { HealthBand, bandOf } from "@/components/health-band";
import { MessageLink } from "@/components/message-link";
import InviteToApp from "@/components/invite-to-app";
import { formatMoney } from "@/lib/plans";
import { dayMonthParts, fmtTime } from "@/lib/time";
import { TimelineList } from "./timeline";
import NotesPanel from "./records/notes";
import GoalsPanel from "./records/goals";
import DocumentsPanel, { PhotoUpload } from "./records/documents";
import { AttendancePattern } from "./attendance";

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
    .select("id, first_name, last_name, email, phone, status, joined_on, source, waiver_signed_at, first_visit_at, last_visit_at, lifetime_visits, current_streak, health_band, health_reason, user_id, avatar_url")
    .eq("id", params.id)
    .maybeSingle();
  if (!m) notFound();

  const manager = isManagerUp(ctx.role);
  // §9 gives front desk payments, so the desk gets the button that takes one.
  const desk = isDeskUp(ctx.role);

  const [
    { data: memberships }, { data: ledger }, { data: visits },
    { data: timeline }, { data: notes }, { data: goals }, { data: tags },
    { data: docs },
  ] = await Promise.all([
    supabase.from("memberships")
      .select("id, plan_id, status, price_cents, currency, starts_on, expires_on, renews_on, credits_remaining, auto_renew, membership_plans(name, type)")
      .eq("member_id", params.id).order("starts_on", { ascending: false }),
    supabase.from("credit_ledger")
      .select("id, delta, reason, balance_after, created_at")
      .eq("member_id", params.id).order("created_at", { ascending: false }).limit(12),
    supabase.from("check_ins")
      .select("id, checked_in_at")
      .eq("member_id", params.id).order("checked_in_at", { ascending: false }).limit(600),
    supabase.from("timeline_events")
      .select("id, type, occurred_at, title, description, metadata")
      .eq("member_id", params.id).order("occurred_at", { ascending: false }).limit(200),
    supabase.from("member_notes")
      .select("id, category, body, pinned, managers_only, active, created_at")
      .eq("member_id", params.id).order("pinned", { ascending: false }).order("created_at", { ascending: false }),
    supabase.from("member_goals")
      .select("id, title, target_type, target_value, current_value, target_date, status, completed_at")
      .eq("member_id", params.id).order("status").order("target_date", { nullsFirst: false }),
    supabase.from("member_tag_assignments")
      .select("tag_id, member_tags(name)").eq("member_id", params.id),
    // The medical narrowing lives in the policy, so an instructor or a front
    // desk simply receives fewer rows here rather than this screen filtering.
    supabase.from("member_documents")
      .select("id, kind, filename, storage_path, size_bytes, signed_at, created_at")
      .eq("member_id", params.id).order("created_at", { ascending: false }),
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

  const journey = (timeline ?? []).filter((e) => manager || e.type !== "payment");

  // Goal progress is computed, never read off member_goals.current_value —
  // that column has never been written and every goal read "0 of 12".
  const goalRows = await Promise.all((goals ?? []).map(async (g) => {
    const { data } = await supabase.rpc("member_goal_progress", { p_goal_id: g.id });
    const p = (data ?? {}) as { done?: number; met?: boolean };
    return { ...g, done: p.done ?? 0, met: p.met ?? false };
  }));

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

  const live = (memberships ?? []).find(
    (x) => !["cancelled", "expired"].includes(x.status));
  const past = (memberships ?? []).filter((x) => x.id !== live?.id);

  const d = (iso: string) => {
    const { day, month } = dayMonthParts(iso, ctx.timeZone);
    return <><span className="num">{day}</span> {month}</>;
  };

  return (
    <AppShell
      {...shell}
      title={`${m.first_name} ${m.last_name}`}
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
      {/* An account, or the way to offer one. Not buried in a section: for a
          member who has never been invited this is the single most useful thing
          on the screen, and until now the only way to send one was for an
          operator to copy a link out of a database. */}
      {isDeskUp(ctx.role) && !m.user_id && (
        <section className="mb-6 rounded-xl border border-line bg-surface px-3.5 py-3">
          <SectionLabel>App account</SectionLabel>
          <p className="mb-2.5 mt-1 max-w-[58ch] text-[13px] leading-[19px] text-ink-2">
            {m.email
              ? <>{m.first_name} cannot sign in yet. An invite emails them a link to set a
                  password — from {ctx.studioName}, with nothing to download.</>
              : <>{m.first_name} has no email address, so there is nowhere to send an
                  invite. Add one to their record first.</>}
          </p>
          {m.email && <InviteOne memberId={params.id} />}
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
          ? <PhotoUpload memberId={m.id} name={`${m.first_name} ${m.last_name}`} url={photo} />
          : photo && (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={photo} alt="" aria-hidden className="h-16 w-16 rounded-full object-cover" />
          )}
      </div>
      <p className="mb-1 text-[13px] leading-[20px] text-ink-2">
        {m.email}
        {m.phone && <> · {m.phone}</>}
        {" · joined "}{d(m.joined_on)}
        {m.status !== "active" && <> · {m.status}</>}
        {!m.waiver_signed_at && <> · <span className="text-ink">no waiver signed</span></>}
      </p>
      {/* Whether they can actually use the app they are being messaged about. */}
      <div className="mb-4 mt-2">
        {m.user_id ? (
          <p className="text-[12px] leading-4 text-ink-3">
            Has an account and can use the member app.
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
                <TimelineList events={journey.slice(0, JOURNEY_SHOWN)} timeZone={ctx.timeZone} />
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
            <section className="s-card p-5">
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
          <section className="s-card p-5">
            <h2 className="s-head mb-3">Membership</h2>
            {!live ? (
              <Empty quiet>
                Nothing active.{" "}
                {manager ? "Sell them a plan to get them booking." : "An owner or manager can sell them one."}
              </Empty>
            ) : (
              <div className="rounded-xl px-3 py-2.5" style={{ background: "var(--paper)" }}>
                <div className="text-[14px] leading-5 text-ink">{live.membership_plans?.name}</div>
                <div className="mt-0.5 text-[12px] leading-4 text-ink-3">
                  <span className="num">{formatMoney(live.price_cents, live.currency)}</span>
                  {" · "}{live.status.replace("_", " ")}
                  {live.renews_on && <> · renews {d(live.renews_on)}</>}
                  {live.expires_on && <> · expires {d(live.expires_on)}</>}
                  {!live.auto_renew && <> · will not renew</>}
                </div>
                <div className="mt-2 text-[13px] leading-[18px] text-ink">
                  {live.credits_remaining === null
                    ? "Unlimited classes"
                    : <><span className="num">{live.credits_remaining}</span> credit
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
    </AppShell>
  );
}
