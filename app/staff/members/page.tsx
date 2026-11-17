import Link from "next/link";
import { isDeskUp, isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { dayMonthParts } from "@/lib/time";
import { relativeDay } from "@/lib/relative-day";
import { AppShell, Empty, NavLink, Pill, PillRow, Rows, Segmented } from "@/components/ui";
import { HealthBand, HealthChip, bandOf, isLoud } from "@/components/health-band";
import { StateChip } from "@/components/state-chip";
import { MessageLink } from "@/components/message-link";
import MembersSearch from "@/components/staff/members-search";
import MembersExport from "@/components/staff/members-export";

export const dynamic = "force-dynamic";

/**
 * Decision 105: the Members list is one staff-only reader (members_list) with a
 * search box, filter chips with live counts, a sort control, and a phone-width
 * card per row. The health band (Decision 14) stays on the rows as the loud
 * signal it always was; the chips are the new, quick filters.
 */

type Row = {
  id: string; first_name: string; last_name: string; email: string; phone: string | null;
  status: string; lifetime_visits: number; last_visit_at: string | null;
  health_band: string | null; health_reason: string | null; user_id: string | null;
  current_plan_name: string | null; plan_type: string | null;
  expires_on: string | null; credits_remaining: number | null;
  plan_state: string; complimentary: boolean; free_stage: string | null;
  has_unpaid_booking: boolean; joined_on: string | null; reservation_fee_waived: boolean;
  has_duplicate: boolean; has_fee_due: boolean; needs_waiver: boolean;
  email_status: string | null;
  deleted: boolean; deleted_at: string | null; merged_into: string | null;
};
type Counts = Record<string, number>;
type Result = { rows: Row[]; counts: Counts; total: number };

const FILTERS: { key: string; label: string; countKey: string }[] = [
  { key: "all", label: "All", countKey: "all" },
  { key: "active", label: "Active", countKey: "active" },
  { key: "leads", label: "Leads", countKey: "leads" },
  { key: "unpaid", label: "Unpaid", countKey: "unpaid" },
  { key: "free_pending", label: "Free class pending", countKey: "free_pending" },
  { key: "attention", label: "Needs attention", countKey: "attention" },
  { key: "deleted", label: "Deleted", countKey: "deleted" },
];

export default async function Members({
  searchParams,
}: {
  searchParams: { q?: string; filter?: string; sort?: string };
}) {
  const screen = await staffScreen("/members");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  const q = (searchParams.q ?? "").toString();
  const filter = (searchParams.filter ?? "all").toString();
  const sort = (searchParams.sort ?? "attention").toString();

  const { data } = await supabase.rpc("members_list", {
    p_studio_id: ctx.studioId, p_search: q, p_filter: filter, p_sort: sort, p_page: 1,
  });
  const { data: studioRow } = await supabase.from("studios").select("slug").eq("id", ctx.studioId).maybeSingle();
  const exportSlug = studioRow?.slug ?? ctx.studioName;
  const res = (data ?? { rows: [], counts: {}, total: 0 }) as Result;
  const rows = res.rows ?? [];
  const counts = res.counts ?? {};

  // Deleted rows name who they were merged into (Decision 97).
  const mergedIds = Array.from(new Set(rows.map((r) => r.merged_into).filter(Boolean))) as string[];
  const names = new Map<string, string>();
  if (mergedIds.length) {
    const { data: keeps } = await supabase.from("members").select("id, first_name, last_name").in("id", mergedIds);
    for (const k of keeps ?? []) names.set(k.id, `${k.first_name} ${k.last_name}`.trim());
  }

  const href = (patch: { filter?: string | null; sort?: string | null }) => {
    const params = new URLSearchParams();
    if (q) params.set("q", q);
    const f = patch.filter === undefined ? filter : patch.filter;
    const s = patch.sort === undefined ? sort : patch.sort;
    if (f && f !== "all") params.set("filter", f);
    if (s && s !== "attention") params.set("sort", s);
    const qs = params.toString();
    return qs ? `/members?${qs}` : "/members";
  };

  return (
    <AppShell
      {...shell}
      title="Members"
      actions={
        <>
          <span className="num text-[13px] text-ink-3">
            {counts.active ?? 0} <span className="font-sans">active</span>
          </span>
          <NavLink href="/members/invites">Invites</NavLink>
          <NavLink href="/members/new">Add a member</NavLink>
          {isManagerUp(ctx.role) && (
            <MembersExport slug={exportSlug} q={q} filter={filter} sort={sort} />
          )}
        </>
      }
      filters={
        <div className="space-y-2.5">
          <MembersSearch initial={q} />
          <PillRow
            right={
              <Segmented
                options={[
                  { href: href({ sort: "attention" }), label: "By attention", active: sort === "attention" },
                  { href: href({ sort: "last_visit" }), label: "Last visit", active: sort === "last_visit" },
                  { href: href({ sort: "joined" }), label: "Joined", active: sort === "joined" },
                  { href: href({ sort: "name" }), label: "Name", active: sort === "name" },
                ]}
              />
            }
          >
            {FILTERS.map((f) => (
              <Pill key={f.key} href={href({ filter: f.key })} active={filter === f.key}>
                {f.label}
                <span className="num ml-1.5 opacity-60">{counts[f.countKey] ?? 0}</span>
              </Pill>
            ))}
          </PillRow>
        </div>
      }
    >
      {rows.length === 0 ? (
        <Empty>
          {(counts.all ?? 0) === 0 && !q ? (
            <>
              No members yet.{" "}
              {isManagerUp(ctx.role) ? (
                <>
                  <Link href="/imports" className="text-lime-text underline underline-offset-4">
                    Bring your existing ones across
                  </Link>{" "}
                  from a CSV, or they will appear here as people sign up.
                </>
              ) : (
                <>They will appear here as people sign up.</>
              )}
            </>
          ) : (
            <>
              Nobody matches{q ? <> &ldquo;{q}&rdquo;</> : <> that filter</>} right now.{" "}
              <Link href={href({ filter: "all", sort: null })} className="text-lime-text underline underline-offset-4">
                Show everyone
              </Link>
              .
            </>
          )}
        </Empty>
      ) : (
        <Rows>
          {rows.map((m) => {
            const band = m.health_band ? bandOf(m.health_band) : null;
            const loud = !m.deleted && band != null && isLoud(band) && !!m.health_reason;
            const statusChip = m.deleted
              ? (m.merged_into ? `Merged into ${names.get(m.merged_into) ?? "another member"}` : "Deleted")
              : m.has_unpaid_booking ? "Unpaid"
              : m.status === "lead" ? "Lead"
              : "Active";
            const lastVisit = relativeDay(m.last_visit_at, ctx.timeZone);
            return (
              <div key={m.id} className={`relative hover:bg-paper ${loud ? "px-3 py-3" : "px-3 py-2.5"}`}>
                <div className={`flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 ${loud ? "mb-1.5" : ""}`}>
                  <span className="flex min-w-0 flex-wrap items-center gap-2">
                    <Link
                      href={`/members/${m.id}`}
                      className={`truncate text-[14px] font-medium leading-5 ${m.deleted ? "text-ink-2" : "text-ink"} after:absolute after:inset-0 after:content-['']`}
                    >
                      {m.first_name} {m.last_name}
                    </Link>
                    <StatusPill label={statusChip} tone={m.deleted ? "muted" : m.has_unpaid_booking ? "warn" : "ok"} />
                    {!loud && !m.deleted && band != null && ((m.lifetime_visits ?? 0) > 0 || band === "new") && <HealthChip band={band} />}
                    {!m.user_id && !m.deleted && (
                      <span className="shrink-0 rounded-sm bg-line px-1.5 py-0.5 text-[10px] uppercase leading-4 tracking-[0.06em] text-ink-2">
                        No app
                      </span>
                    )}
                  </span>
                  <span className="flex items-center gap-3 text-[12px] leading-4 text-ink-3">
                    {!m.deleted && (
                      <span>
                        <span className="num">{m.lifetime_visits ?? 0}</span>
                        {" visit"}{(m.lifetime_visits ?? 0) === 1 ? "" : "s"}
                        {lastVisit && <> · {lastVisit}</>}
                      </span>
                    )}
                    {m.deleted && m.deleted_at && (() => {
                      const { day, month } = dayMonthParts(m.deleted_at, ctx.timeZone);
                      return <span><span className="num">{day}</span> {month}</span>;
                    })()}
                    {loud && isDeskUp(ctx.role) && (
                      <MessageLink href={`/members/${m.id}/message`} className="relative z-10" />
                    )}
                  </span>
                </div>
                {!m.deleted && (
                  <div className="flex flex-wrap items-center gap-x-2 gap-y-1 text-[12px] leading-4 text-ink-3">
                    <PlanLine m={m} timeZone={ctx.timeZone} />
                    {m.phone && (
                      <a href={`tel:${m.phone.replace(/\s/g, "")}`} className="relative z-10 text-ink-2 underline underline-offset-2">
                        {m.phone}
                      </a>
                    )}
                    {m.has_duplicate && <StateChip state="duplicate" />}
                    {m.reservation_fee_waived && <StateChip state="fee_waived" />}
                    {m.has_fee_due && <StateChip state="fee_due" />}
                    {m.needs_waiver && <StateChip state="no_waiver" />}
                    {m.email_status && m.email_status !== "valid" && <StateChip state="email_bounced" />}
                  </div>
                )}
                {loud && band != null && <HealthBand band={band} reason={m.health_reason ?? ""} />}
              </div>
            );
          })}
        </Rows>
      )}
    </AppShell>
  );
}

function StatusPill({ label, tone }: { label: string; tone: "ok" | "warn" | "muted" }) {
  const cls =
    tone === "warn" ? "border-line-2 bg-amber-tint text-ink"
    : tone === "muted" ? "border-line-2 bg-paper text-ink-3"
    : "border-line-2 bg-paper text-ink-2";
  return (
    <span className={`inline-flex shrink-0 items-center rounded-sm border px-1.5 py-px text-[11px] leading-4 ${cls}`}>
      {label}
    </span>
  );
}

/** The plan name and its expiry/credits, with a chip for the states that ask
 *  something of the studio. */
function PlanLine({ m, timeZone }: { m: Row; timeZone: string }) {
  const ps = m.plan_state;
  if (m.has_unpaid_booking) return <StateChip state="unpaid_booking" />;
  if (ps === "free_only") {
    const stage = m.free_stage === "booked" ? "free_booked"
      : m.free_stage === "taken" ? "free_taken"
      : m.free_stage === "missed" ? "free_missed"
      : m.free_stage === "late_cancel" ? "free_late_cancel"
      : "free_only";
    return <StateChip state={stage} />;
  }
  if (ps === "none") return <StateChip state="none" />;

  const detail: React.ReactNode[] = [];
  if (m.plan_type === "recurring" && !m.expires_on) {
    detail.push(<span key="r">renews</span>);
  } else {
    if (m.credits_remaining != null && m.credits_remaining > 0) {
      detail.push(
        <span key="c">
          <span className="num">{m.credits_remaining}</span> credit{m.credits_remaining === 1 ? "" : "s"}
        </span>,
      );
    }
    if (m.expires_on) {
      const { day, month } = dayMonthParts(m.expires_on, timeZone);
      detail.push(<span key="e">expires <span className="num">{day}</span> {month}</span>);
    }
  }

  return (
    <>
      <span className="text-ink-2">{m.current_plan_name ?? "No plan"}</span>
      {detail.map((d, i) => <span key={i}>· {d}</span>)}
      {m.complimentary && <StateChip state="complimentary" />}
      {(ps === "expiring" || ps === "expired") && <StateChip state={ps} />}
    </>
  );
}
