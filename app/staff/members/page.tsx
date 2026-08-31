import Link from "next/link";
import { isDeskUp, isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { dayMonthParts } from "@/lib/time";
import { AppShell, Empty, Pill, PillRow, Rows } from "@/components/ui";
import { HealthBand, HealthChip, bandOf, isLoud, type Band } from "@/components/health-band";
import { MessageLink } from "@/components/message-link";

export const dynamic = "force-dynamic";

/**
 * The member list is where the health band lives.
 *
 * Rows are two lines rather than one, and the reason runs to its full length.
 * That breaks the 44px row height everywhere else in the app, deliberately:
 * "was coming about every 4 days, last visit 14 days ago" is the entire value
 * of the band, and a truncated reason is a badge with extra steps.
 */

const FILTERS: { key: string; label: string; bands?: Band[] }[] = [
  { key: "attention", label: "Needs attention", bands: ["at_risk", "drifting"] },
  { key: "at_risk", label: "At risk", bands: ["at_risk"] },
  { key: "drifting", label: "Drifting", bands: ["drifting"] },
  { key: "new", label: "New", bands: ["new"] },
  { key: "healthy", label: "Healthy", bands: ["healthy"] },
];

export default async function Members({
  searchParams,
}: {
  searchParams: { filter?: string };
}) {
  const screen = await staffScreen("/members");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  const [{ data: members }] = await Promise.all([
    supabase
      .from("members")
      .select("id, first_name, last_name, email, status, lifetime_visits, last_visit_at, health_band, health_reason")
      .neq("status", "archived")
      .order("last_visit_at", { ascending: false, nullsFirst: false })
      .limit(500),
  ]);

  const filter = searchParams.filter ?? "";
  const spec = FILTERS.find((f) => f.key === filter);
  const all = members ?? [];

  // "payment" and "past_due" arrive from the banner, and are membership
  // states rather than health bands — handled separately so the pills stay
  // about health and the banner still has somewhere to point.
  let shown = all;
  let membershipFilterLabel: string | null = null;
  if (filter === "past_due" || filter === "payment") {
    const { data: rows } = await supabase
      .from("memberships")
      .select("member_id")
      .eq("status", "past_due");
    const ids = new Set((rows ?? []).map((r) => r.member_id));
    shown = all.filter((m) => ids.has(m.id));
    membershipFilterLabel = "Past due";
  } else if (spec?.bands) {
    shown = all.filter((m) => spec.bands!.includes(bandOf(m.health_band)));
  }

  const count = (bands: Band[]) =>
    all.filter((m) => bands.includes(bandOf(m.health_band))).length;

  const href = (k?: string) => (k ? `/members?filter=${k}` : "/members");

  // Whoever needs something comes first. Sorting by last visit put five
  // healthy regulars at the top of the screen whose whole job is surfacing the
  // member you would otherwise miss.
  const SEVERITY: Record<Band, number> = {
    at_risk: 0, drifting: 1, new: 2, insufficient_history: 3, healthy: 4,
  };
  const ordered = [...shown].sort(
    (a, b) => SEVERITY[bandOf(a.health_band)] - SEVERITY[bandOf(b.health_band)],
  );

  return (
    <AppShell
      {...shell}
      title="Members"
      actions={
        <span className="num text-[13px] text-ink-3">
          {all.length} <span className="font-sans">active</span>
        </span>
      }
      filters={
        <PillRow>
          <Pill href={href()} active={!filter}>Everyone</Pill>
          {FILTERS.map((f) => {
            const n = f.bands ? count(f.bands) : 0;
            return (
              <Pill key={f.key} href={href(f.key)} active={filter === f.key}>
                {f.label}
                {n > 0 && <span className="num ml-1.5 opacity-60">{n}</span>}
              </Pill>
            );
          })}
          {membershipFilterLabel && (
            <Pill href={href(filter)} active>{membershipFilterLabel}</Pill>
          )}
        </PillRow>
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
              Nobody is in that state right now.{" "}
              <Link href={href()} className="text-lime-text underline underline-offset-4">
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
                    {!loud && <HealthChip band={band} />}
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
                {loud && <HealthBand band={band} reason={m.health_reason} />}
              </div>
            );
          })}
        </Rows>
      )}
    </AppShell>
  );
}
