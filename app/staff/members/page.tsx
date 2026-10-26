import Link from "next/link";
import { isDeskUp, isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { dayMonthParts } from "@/lib/time";
import { AppShell, Empty, NavLink, Pill, PillRow, Rows, Segmented } from "@/components/ui";
import { HealthBand, HealthChip, bandOf, isLoud, type Band } from "@/components/health-band";
import { StateChip } from "@/components/state-chip";
import { MessageLink } from "@/components/message-link";
import { defaultSortMode } from "@/lib/members-list";

export const dynamic = "force-dynamic";

/**
 * The member list is where the health band lives.
 *
 * Rows are two lines rather than one, and the reason runs to its full length.
 * That breaks the 44px row height everywhere else in the app, deliberately:
 * "was coming about every 4 days, last visit 14 days ago" is the entire value
 * of the band, and a truncated reason is a badge with extra steps.
 *
 * Decision 49 adds the plan dimension. The rows now come from
 * member_plan_overview(), which carries every field this page already used PLUS
 * the member's plan state — so a second filter row (combinable with health) and
 * a plan line under each name cost no extra query. No amounts: that is Sales.
 */

const FILTERS: { key: string; label: string; bands?: Band[] }[] = [
  { key: "attention", label: "Needs attention", bands: ["at_risk", "drifting"] },
  { key: "at_risk", label: "At risk", bands: ["at_risk"] },
  { key: "drifting", label: "Drifting", bands: ["drifting"] },
  { key: "new", label: "New", bands: ["new"] },
  { key: "healthy", label: "Healthy", bands: ["healthy"] },
];

// Combinable with the health filter, on its own `plan` param. "On a plan"
// gathers the two usable states; the free cohort (plan_state 'free_only') is
// split by free_stage (Members list polish, 20 Oct 2026); the rest map to one
// plan_state each. Matches the whole row (free_stage + plan_state).
const PLAN_FILTERS: { key: string; label: string; match: (m: Row) => boolean }[] = [
  { key: "on_plan", label: "On a plan", match: (m) => m.plan_state === "on_plan" || m.plan_state === "expiring" },
  { key: "expiring", label: "Expiring (14 days)", match: (m) => m.plan_state === "expiring" },
  { key: "expired", label: "Expired", match: (m) => m.plan_state === "expired" },
  { key: "free_booked", label: "Free class booked", match: (m) => m.plan_state === "free_only" && m.free_stage === "booked" },
  { key: "free_taken", label: "Free class taken", match: (m) => m.plan_state === "free_only" && m.free_stage === "taken" },
  { key: "free_missed", label: "Free class missed", match: (m) => m.plan_state === "free_only" && m.free_stage === "missed" },
  { key: "unpaid", label: "Unpaid booking", match: (m) => m.has_unpaid_booking },
  // A member with an unpaid booking is excluded here — they DID book.
  { key: "none", label: "Signed up, nothing booked", match: (m) => m.plan_state === "none" && !m.has_unpaid_booking },
];

type Row = {
  id: string; first_name: string; last_name: string; email: string;
  status: string; lifetime_visits: number; last_visit_at: string | null;
  health_band: string; health_reason: string; user_id: string | null;
  current_plan_name: string | null; plan_type: string | null;
  expires_on: string | null; credits_remaining: number | null;
  plan_state: string; complimentary: boolean; free_stage: string | null;
  has_unpaid_booking: boolean;
};

export default async function Members({
  searchParams,
}: {
  searchParams: { filter?: string; plan?: string; sort?: string };
}) {
  const screen = await staffScreen("/members");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  const { data: rows } = await supabase.rpc("member_plan_overview", {
    p_studio_id: ctx.studioId,
  });
  const all = (rows ?? []) as Row[];

  const filter = searchParams.filter ?? "";
  const planFilter = searchParams.plan ?? "";
  const sort = searchParams.sort ?? "";
  const spec = FILTERS.find((f) => f.key === filter);
  const planSpec = PLAN_FILTERS.find((p) => p.key === planFilter);

  // "payment" and "past_due" arrive from the banner, and are membership states
  // rather than health bands — kept as the member-id intersection they always
  // were so the banner keeps pointing at the right people.
  let shown = all;
  let membershipFilterLabel: string | null = null;
  if (filter === "past_due" || filter === "payment") {
    const { data: due } = await supabase
      .from("memberships")
      .select("member_id")
      .eq("status", "past_due");
    const ids = new Set((due ?? []).map((r) => r.member_id));
    shown = shown.filter((m) => ids.has(m.id));
    membershipFilterLabel = "Past due";
  } else if (filter === "no_app") {
    shown = shown.filter((m) => !m.user_id);
    membershipFilterLabel = "No app yet";
  } else if (spec?.bands) {
    shown = shown.filter((m) => spec.bands!.includes(bandOf(m.health_band)));
  }

  // The plan filter is an AND on top of the health filter.
  if (planSpec) shown = shown.filter((m) => planSpec.match(m));
  // Backward compatible: ?plan=free_only still works, mapping to the three free
  // chips combined (the whole free cohort).
  else if (planFilter === "free_only") shown = shown.filter((m) => m.plan_state === "free_only");
  // Decision 61: "Complimentary" is a flag, not a plan_state.
  else if (planFilter === "complimentary") shown = shown.filter((m) => m.complimentary);

  const count = (bands: Band[]) =>
    all.filter((m) => bands.includes(bandOf(m.health_band))).length;
  const planCount = (p: (typeof PLAN_FILTERS)[number]) =>
    all.filter((m) => p.match(m)).length;

  const href = (patch: { filter?: string | null; plan?: string | null; sort?: string | null }) => {
    const f = patch.filter === undefined ? filter : patch.filter;
    const p = patch.plan === undefined ? planFilter : patch.plan;
    const s = patch.sort === undefined ? sort : patch.sort;
    const params = new URLSearchParams();
    if (f) params.set("filter", f);
    if (p) params.set("plan", p);
    if (s) params.set("sort", s);
    const q = params.toString();
    return q ? `/members?${q}` : "/members";
  };

  // Whoever needs something comes first. Sorting by last visit put five healthy
  // regulars at the top of the screen whose whole job is surfacing the member
  // you would otherwise miss. The alternative sort — soonest to expire first —
  // is what somebody chasing renewals wants, so it is a toggle, not the default.
  const SEVERITY: Record<Band, number> = {
    at_risk: 0, drifting: 1, new: 2, insufficient_history: 3, healthy: 4,
  };
  // Members list polish (20 Oct 2026): a studio where nobody has visited yet has
  // no attention to sort by — newest sign-up is the sensible default there. The
  // user's explicit "By expiry" always wins; otherwise the mode decides.
  const sortMode = sort === "expiry" ? "expiry" : defaultSortMode(all);
  let joinedMap: Map<string, string | null> | null = null;
  if (sortMode === "newest") {
    const { data: jr } = await supabase
      .from("members").select("id, joined_on").eq("studio_id", ctx.studioId);
    joinedMap = new Map((jr ?? []).map((r) => [r.id, r.joined_on]));
  }
  const joinedTs = (m: Row) => {
    const j = joinedMap?.get(m.id);
    return j ? Date.parse(j) : 0;
  };
  const ordered =
    sortMode === "expiry"
      ? [...shown].sort((a, b) => {
          const ax = a.expires_on ? Date.parse(a.expires_on) : Infinity;
          const bx = b.expires_on ? Date.parse(b.expires_on) : Infinity;
          return ax - bx;
        })
      : sortMode === "newest"
      ? [...shown].sort((a, b) => joinedTs(b) - joinedTs(a))
      : [...shown].sort(
          (a, b) => SEVERITY[bandOf(a.health_band)] - SEVERITY[bandOf(b.health_band)],
        );

  const emptyName = planSpec?.label ?? spec?.label ?? membershipFilterLabel ?? null;

  return (
    <AppShell
      {...shell}
      title="Members"
      actions={
        <>
          <span className="num text-[13px] text-ink-3">
            {all.length} <span className="font-sans">active</span>
          </span>
          <NavLink href="/members/invites">Invites</NavLink>
          <NavLink href="/members/new">Add a member</NavLink>
        </>
      }
      filters={
        <div className="space-y-2">
          <PillRow
            right={
              <Segmented
                options={[
                  { href: href({ sort: null }), label: "By attention", active: sort !== "expiry" },
                  { href: href({ sort: "expiry" }), label: "By expiry", active: sort === "expiry" },
                ]}
              />
            }
          >
            <Pill href={href({ filter: null })} active={!filter}>Everyone</Pill>
            {FILTERS.map((f) => {
              const n = f.bands ? count(f.bands) : 0;
              return (
                <Pill key={f.key} href={href({ filter: f.key })} active={filter === f.key}>
                  {f.label}
                  <span className="num ml-1.5 opacity-60">{n}</span>
                </Pill>
              );
            })}
            <Pill href={href({ filter: "no_app" })} active={filter === "no_app"}>
              No app
              <span className="num ml-1.5 opacity-60">{all.filter((m) => !m.user_id).length}</span>
            </Pill>
            {membershipFilterLabel && (filter === "past_due" || filter === "payment") && (
              <Pill href={href({ filter })} active>{membershipFilterLabel}</Pill>
            )}
          </PillRow>
          <PillRow>
            <Pill href={href({ plan: null })} active={!planFilter}>All plans</Pill>
            {PLAN_FILTERS.map((p) => {
              const n = planCount(p);
              return (
                <Pill key={p.key} href={href({ plan: p.key })} active={planFilter === p.key}>
                  {p.label}
                  <span className="num ml-1.5 opacity-60">{n}</span>
                </Pill>
              );
            })}
            {(() => {
              const n = all.filter((m) => m.complimentary).length;
              return (
                <Pill href={href({ plan: "complimentary" })} active={planFilter === "complimentary"}>
                  Complimentary
                  <span className="num ml-1.5 opacity-60">{n}</span>
                </Pill>
              );
            })()}
          </PillRow>
        </div>
      }
    >
      {shown.length === 0 ? (
        <Empty>
          {all.length === 0 ? (
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
              {emptyName ? <>Nobody matches {emptyName.toLowerCase()} right now.</> : <>Nobody is in that state right now.</>}{" "}
              <Link href={href({ filter: null, plan: null })} className="text-lime-text underline underline-offset-4">
                Show everyone
              </Link>
              .
            </>
          )}
        </Empty>
      ) : (
        <Rows>
          {ordered.map((m) => {
            const band = bandOf(m.health_band);
            const loud = isLoud(band) && !!m.health_reason;
            return (
              // The row cannot be one big anchor any more: the message action is
              // itself a link and an anchor inside an anchor is invalid markup
              // that swallows the inner click. The name is stretched over the
              // row with ::after so the whole thing still navigates, and the
              // action is raised above it.
              <div
                key={m.id}
                className={`relative hover:bg-paper ${loud ? "px-3 py-3" : "px-3 py-2.5"}`}
              >
                <div className={`flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 ${loud ? "mb-1.5" : ""}`}>
                  <span className="flex min-w-0 items-center gap-2.5">
                    <Link
                      href={`/members/${m.id}`}
                      className="truncate text-[14px] font-medium leading-5 text-ink after:absolute after:inset-0 after:content-['']"
                    >
                      {m.first_name} {m.last_name}
                    </Link>
                    {/* Members list polish (20 Oct 2026): no health chip for a
                        member with zero visits — the band can't say anything yet.
                        "New" (a recent sign-up) stays. */}
                    {!loud && ((m.lifetime_visits ?? 0) > 0 || band === "new") && <HealthChip band={band} />}
                    {/* Quiet, and only on the ones without. A tick on every
                        row that has an account is a column of ticks; the
                        useful signal is the absence. */}
                    {!m.user_id && (
                      <span className="shrink-0 rounded-sm bg-line px-1.5 py-0.5 text-[10px] uppercase leading-4 tracking-[0.06em] text-ink-2">
                        No app
                      </span>
                    )}
                  </span>
                  <span className="flex items-center gap-3 text-[12px] leading-4 text-ink-3">
                    <span>
                    <span className="num">{m.lifetime_visits ?? 0}</span>
                    {" visit"}{(m.lifetime_visits ?? 0) === 1 ? "" : "s"}
                    {m.last_visit_at && (() => {
                      const { day, month } = dayMonthParts(m.last_visit_at, ctx.timeZone);
                      return <>{" · last on "}<span className="num">{day}</span>{` ${month}`}</>;
                    })()}
                    </span>
                    {/* Non-healthy only. Eight "Message" links down a column of
                        healthy members is noise attached to the rows that need
                        nothing doing. */}
                    {loud && isDeskUp(ctx.role) && (
                      <MessageLink href={`/members/${m.id}/message`} className="relative z-10" />
                    )}
                  </span>
                </div>
                {/* The plan line, stacked under the name so it reads at phone
                    width while the visit meta stays on the right. */}
                <div className="flex flex-wrap items-center gap-x-2 gap-y-1 text-[12px] leading-4 text-ink-3">
                  <PlanLine m={m} timeZone={ctx.timeZone} />
                </div>
                {loud && <HealthBand band={band} reason={m.health_reason} />}
              </div>
            );
          })}
        </Rows>
      )}
    </AppShell>
  );
}

/** The plan name and its expiry/credits, with a chip for the states that ask
 *  something of the studio. "On a plan" is the normal good state and carries no
 *  chip; free-only and no-plan carry the chip alone. */
function PlanLine({ m, timeZone }: { m: Row; timeZone: string }) {
  const ps = m.plan_state;
  // A live unpaid drop-in on a future class — shown in place of "Signed up,
  // nothing booked" (they DID book). Takes precedence, since it asks the studio
  // to collect payment.
  if (m.has_unpaid_booking) return <StateChip state="unpaid_booking" />;
  // Members list polish (20 Oct 2026): the free cohort shows its stage in place
  // of "Free class only"; "none" is renamed via the chip. A free_only member
  // with no resolvable stage (comp cancelled) falls back to "Free class only".
  if (ps === "free_only") {
    const stage = m.free_stage === "booked" ? "free_booked"
      : m.free_stage === "taken" ? "free_taken"
      : m.free_stage === "missed" ? "free_missed"
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
      <span className="text-ink-2">{m.current_plan_name ?? "—"}</span>
      {detail.map((d, i) => <span key={i}>· {d}</span>)}
      {m.complimentary && <StateChip state="complimentary" />}
      {(ps === "expiring" || ps === "expired") && <StateChip state={ps} />}
    </>
  );
}
