import Link from "next/link";
import { notFound } from "next/navigation";
import { isDeskUp, isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Empty, NavLink, Rows, SectionLabel } from "@/components/ui";
import { HealthBand, bandOf } from "@/components/health-band";
import { MessageLink } from "@/components/message-link";
import { formatMoney } from "@/lib/plans";
import { dayMonthParts, fmtTime } from "@/lib/time";
import { TimelineList } from "./timeline";
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
  searchParams: { sent?: string };
}) {
  const screen = await staffScreen("/members");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  const { data: m } = await supabase
    .from("members")
    .select("id, first_name, last_name, email, phone, status, joined_on, source, waiver_signed_at, first_visit_at, last_visit_at, lifetime_visits, current_streak, health_band, health_reason")
    .eq("id", params.id)
    .maybeSingle();
  if (!m) notFound();

  const manager = isManagerUp(ctx.role);

  const [
    { data: memberships }, { data: ledger }, { data: visits },
    { data: timeline }, { data: notes }, { data: goals }, { data: tags },
  ] = await Promise.all([
    supabase.from("memberships")
      .select("id, status, price_cents, currency, starts_on, expires_on, renews_on, credits_remaining, auto_renew, membership_plans(name, type)")
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
        .select("id, amount_cents, currency, status, description, card_brand, card_last4, paid_at, created_at, failure_message")
        .eq("member_id", params.id).order("created_at", { ascending: false }).limit(20)
    : { data: null };

  const journey = (timeline ?? []).filter((e) => manager || e.type !== "payment");

  const live = (memberships ?? []).find(
    (x) => !["cancelled", "expired"].includes(x.status));
  const past = (memberships ?? []).filter((x) => x.id !== live?.id);
  const openGoals = (goals ?? []).filter((g) => g.status !== "completed");
  const doneGoals = (goals ?? []).filter((g) => g.status === "completed");

  const d = (iso: string) => {
    const { day, month } = dayMonthParts(iso, ctx.timeZone);
    return <><span className="num">{day}</span> {month}</>;
  };

  return (
    <AppShell
      {...shell}
      title={`${m.first_name} ${m.last_name}`}
      actions={<NavLink href="/members">Back to members</NavLink>}
    >
      {searchParams.sent && (
        <p className="mb-4 border-l-[3px] px-3 py-2 text-[13px] leading-[18px] text-ink"
           style={{ borderLeftColor: "var(--lime-text)", background: "var(--lime-tint)" }}>
          Queued. It will go out on the next send — nothing has left yet, and it
          is on {m.first_name}&rsquo;s journey below.
        </p>
      )}
      <p className="mb-1 text-[13px] leading-[20px] text-ink-2">
        {m.email}
        {m.phone && <> · {m.phone}</>}
        {" · joined "}{d(m.joined_on)}
        {m.status !== "active" && <> · {m.status}</>}
        {!m.waiver_signed_at && <> · <span className="text-ink">no waiver signed</span></>}
      </p>
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

      <div className="grid gap-8 lg:grid-cols-[minmax(0,1fr)_320px]">
        {/* ---------- the narrative ---------- */}
        <div className="space-y-8">
          <section>
            <SectionLabel>Attendance</SectionLabel>
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

          <section>
            <SectionLabel>Journey</SectionLabel>
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
            <section>
              <SectionLabel>Payments</SectionLabel>
              {(payments ?? []).length === 0 ? (
                <Empty>Nothing has been charged to this member yet.</Empty>
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
                          {p.card_brand && <> · {p.card_brand} ····{p.card_last4}</>}
                          {p.status !== "succeeded" && <> · {p.status.replace("_", " ")}</>}
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
          <section>
            <SectionLabel>Membership</SectionLabel>
            {!live ? (
              <Empty quiet>
                Nothing active.{" "}
                {manager ? "Sell them a plan to get them booking." : "An owner or manager can sell them one."}
              </Empty>
            ) : (
              <div className="border-y border-line bg-surface px-3 py-2.5">
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
              </div>
            )}
            {past.length > 0 && (
              <p className="mt-2 text-[11px] leading-4 text-ink-3">
                {past.length} earlier membership{past.length === 1 ? "" : "s"}, kept at the price
                {past.length === 1 ? " it was" : " they were"} bought at.
              </p>
            )}
          </section>

          <section>
            <SectionLabel>Credits</SectionLabel>
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

          <section>
            <SectionLabel>Notes</SectionLabel>
            {(notes ?? []).length === 0 ? (
              <Empty quiet>
                No notes yet. Injuries, preferences and anything the next person on the desk should know.
              </Empty>
            ) : (
              <div className="space-y-2">
                {(notes ?? []).map((n) => (
                  <div key={n.id}
                       className={`border-l-[3px] bg-surface px-3 py-2 ${n.active ? "" : "opacity-60"}`}
                       style={{ borderLeftColor: n.pinned ? "var(--coral)" : "var(--line-2)" }}>
                    <div className="mb-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-[11px] leading-4 text-ink-3">
                      <span className="capitalize">{n.category}</span>
                      {n.pinned && <span className="text-ink">Shows on the roster</span>}
                      {n.managers_only && (
                        <span className="rounded-sm bg-line px-1.5 py-0.5 text-ink-2">Managers only</span>
                      )}
                      {!n.active && <span>Resolved</span>}
                    </div>
                    <p className="text-[13px] leading-[19px] text-ink">{n.body}</p>
                  </div>
                ))}
              </div>
            )}
            {!manager && (
              <p className="mt-2 text-[11px] leading-4 text-ink-3">
                Managers-only notes are not listed here and are not sent to your browser.
              </p>
            )}
          </section>

          <section>
            <SectionLabel>Goals</SectionLabel>
            {openGoals.length === 0 && doneGoals.length === 0 ? (
              <Empty quiet>No goals set. One is usually enough to give a conversation somewhere to go.</Empty>
            ) : (
              <div className="space-y-3">
                {openGoals.map((g) => {
                  const pct = g.target_value
                    ? Math.min(100, Math.round((g.current_value / g.target_value) * 100))
                    : null;
                  return (
                    <div key={g.id}>
                      <div className="flex items-baseline justify-between gap-3">
                        <span className="text-[13px] leading-[18px] text-ink">{g.title}</span>
                        {g.target_value != null && (
                          <span className="num shrink-0 text-[12px] text-ink-3">
                            {g.current_value}/{g.target_value}
                          </span>
                        )}
                      </div>
                      {pct !== null && (
                        <div className="mt-1 h-1.5 w-full overflow-hidden rounded-full bg-line">
                          <div className="h-full bg-lime" style={{ width: `${pct}%` }} />
                        </div>
                      )}
                      {g.target_date && (
                        <div className="mt-1 text-[11px] leading-4 text-ink-3">by {d(g.target_date)}</div>
                      )}
                    </div>
                  );
                })}
                {doneGoals.map((g) => (
                  <div key={g.id} className="flex items-baseline justify-between gap-3">
                    <span className="text-[13px] leading-[18px] text-ink-3 line-through">{g.title}</span>
                    <span className="shrink-0 text-[11px] leading-4 text-ink-3">
                      {g.completed_at ? <>met {d(g.completed_at)}</> : "met"}
                    </span>
                  </div>
                ))}
              </div>
            )}
          </section>
        </div>
      </div>
    </AppShell>
  );
}
