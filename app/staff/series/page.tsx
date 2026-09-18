import { cookies } from "next/headers";
import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { SetupShell, SetupRow, ArchivedSection } from "@/components/setup-list";
import { TierMark, tierOf, tierWords, tierPhrase } from "@/components/tier-mark";
import { parseRrule, describeRule } from "@/lib/rrule";
import { studioToday } from "@/lib/tz";
import ViewTabs from "./tabs";
import SeriesFilters from "./filters";
import SeriesGrid, { type GridSeries } from "./grid";

export const dynamic = "force-dynamic";

const toMin = (t: string) => { const [h, m] = t.split(":").map(Number); return h * 60 + (m || 0); };

export default async function SeriesList({
  searchParams,
}: { searchParams: { view?: string; ended?: string; tier?: string; type?: string } }) {
  const screen = await staffScreen("/series");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return (
      <AppShell {...shell} title="Recurring classes">
        <Denied what="Changing the timetable" role={ctx.role} />
      </AppShell>
    );
  }

  const view: "list" | "grid" =
    searchParams.view === "grid" ? "grid"
    : searchParams.view === "list" ? "list"
    : cookies().get("series_view")?.value === "grid" ? "grid" : "list";

  const [{ data: series }, { data: settings }, { data: classTypes }] = await Promise.all([
    supabase.from("class_series")
      .select("id, name, rrule, time_of_day, duration_minutes, ends_on, status, capacity, instructor_id, class_type_id, guarantee_tier, flex, minimum_bookings, class_types(name, color), rooms(name)")
      .order("status").order("time_of_day"),
    supabase.from("studio_settings")
      .select("week_starts_on, guarantees_enabled, flex_enabled, flex_min_bookings, core_min_bookings")
      .eq("studio_id", ctx.studioId).maybeSingle(),
    supabase.from("class_types").select("id, name").eq("status", "active").order("name"),
  ]);

  const today = studioToday(ctx.timeZone);
  const isEnded = (s: { status: string | null; ends_on: string | null }) =>
    s.status === "ended" || s.status === "cancelled"
    || (s.ends_on !== null && s.ends_on < today);

  const showTier = (settings?.guarantees_enabled ?? false) || (settings?.flex_enabled ?? false);
  const flexMin = settings?.flex_min_bookings ?? 1;
  const coreMin = settings?.core_min_bookings ?? 1;

  // The FILTER — tier (resolved the same way as the marks, so it can never
  // disagree with the ● / ○ beside a name) and class type, combinable. In the
  // URL, so it is shareable and survives a refresh; a tier filter is honoured
  // only where the studio uses tiers at all.
  const tierParam = showTier && (searchParams.tier === "core" || searchParams.tier === "flex" || searchParams.tier === "always")
    ? searchParams.tier : "";
  const typeParam = searchParams.type && (classTypes ?? []).some((t) => t.id === searchParams.type)
    ? searchParams.type : "";
  const matches = (s: { class_type_id: string | null; guarantee_tier: string | null; flex: boolean | null }) => {
    if (typeParam && s.class_type_id !== typeParam) return false;
    if (tierParam && tierOf(s.guarantee_tier, s.flex) !== tierParam) return false;
    return true;
  };

  const all = series ?? [];
  const isArch = (s: { status: string | null }) => s.status === "archived";
  // Unfiltered, for the grid's STABLE hour range — the shape of the week must
  // not change as you filter, only how many blocks are drawn.
  const uLive = all.filter((s) => !isArch(s) && !isEnded(s));
  const uEnded = all.filter((s) => !isArch(s) && isEnded(s));
  // Filtered, for what is shown. The filter applies within each state.
  const fAll = all.filter(matches);
  const archived = fAll.filter(isArch);
  const ended = fAll.filter((s) => !isArch(s) && isEnded(s));
  const live = fAll.filter((s) => !isArch(s) && !isEnded(s));

  const hideEnded = searchParams.ended === "hide";

  // Preserve every param when changing one (the ended toggle, below).
  const qs = (over: Record<string, string | undefined>) => {
    const p = new URLSearchParams();
    const merged: Record<string, string | undefined> = {
      view, ended: hideEnded ? "hide" : undefined, tier: tierParam || undefined, type: typeParam || undefined, ...over,
    };
    for (const [k, v] of Object.entries(merged)) if (v) p.set(k, v);
    return p.toString();
  };

  const endedToggle =
    (hideEnded ? uEnded : ended).length === 0 && !hideEnded ? null : (
      <Link href={`/series?${qs({ ended: hideEnded ? undefined : "hide" })}`}
            className="text-[12.5px] leading-[18px] text-ink-2 underline underline-offset-4">
        {hideEnded ? `Show ${uEnded.length} ended` : `Hide ${ended.length} ended`}
      </Link>
    );

  // The label the weekly total says it is filtered by, and what the grid appends.
  const typeName = typeParam ? ((classTypes ?? []).find((t) => t.id === typeParam)?.name ?? null) : null;
  const tierName = tierParam ? tierParam[0].toUpperCase() + tierParam.slice(1) : null;
  const filterLabel = [tierName, typeName].filter(Boolean).join(" · ") || null;

  // The grid draws all its hour rows from the unfiltered week; the same range is
  // used whatever the filter, so the grid does not collapse as it narrows.
  const rangeTimes: number[] = [];
  for (const s of [...uLive, ...(hideEnded ? [] : uEnded)]) {
    const { rule, unsupported } = parseRrule(s.rrule);
    if (unsupported || rule.days.length === 0) continue;
    rangeTimes.push(toMin(s.time_of_day));
    rangeTimes.push(Math.min(1440, toMin(s.time_of_day) + s.duration_minutes));
  }
  const hoursFrom = rangeTimes.length ? Math.max(0, Math.floor(Math.min(...rangeTimes) / 60) - 1) : 6;
  const hoursTo = rangeTimes.length ? Math.min(24, Math.ceil(Math.max(...rangeTimes) / 60) + 1) : 20;

  // Classes a week from the FILTERED live series — a series on MWF is three.
  const weeklyClasses = live.reduce((n, s) => {
    const { rule, unsupported } = parseRrule(s.rrule);
    return n + (unsupported ? 0 : rule.days.length);
  }, 0);

  const tierBits = (s: { guarantee_tier: string | null; flex: boolean | null; minimum_bookings: number | null }) => {
    if (!showTier) return { mark: undefined, markLabel: undefined, label: null };
    const t = tierOf(s.guarantee_tier, s.flex);
    return {
      mark: <TierMark tier={t} />,
      markLabel: tierWords(t, s.minimum_bookings, flexMin),
      label: tierPhrase(t, s.minimum_bookings, flexMin, coreMin),
    };
  };

  const meta = (s: (typeof live)[number]) => {
    const { rule, until, unsupported } = parseRrule(s.rrule);
    if (unsupported) return `Repeat rule Studiior cannot keep (${unsupported})`;
    const base = describeRule(rule, s.ends_on ?? until, s.time_of_day);
    const t = tierBits(s).label;
    return t ? `${base} · ${t}` : base;
  };

  const filters = (showTier || (classTypes ?? []).length > 0)
    ? <SeriesFilters showTier={showTier} types={classTypes ?? []} tier={tierParam} type={typeParam} />
    : null;

  const summary = (
    <p className="mb-4 text-[13px] leading-[20px] text-ink-2">
      <span className="num text-[17px] font-semibold text-ink">{weeklyClasses}</span>{" "}
      {weeklyClasses === 1 ? "class" : "classes"} a week
      {live.length > 0 && <> from <span className="num text-ink">{live.length}</span> series</>}
      {filterLabel && <span className="text-ink-3"> · filtered: <span className="text-ink">{filterLabel}</span></span>}
    </p>
  );

  if (view === "grid") {
    const forGrid: GridSeries[] = [...live, ...(hideEnded ? [] : ended)].map((s) => ({
      id: s.id, name: s.name, rrule: s.rrule,
      time_of_day: s.time_of_day, duration_minutes: s.duration_minutes,
      ends_on: s.ends_on, ended: isEnded(s),
      room_name: s.rooms?.name ?? null,
      class_type_id: s.class_type_id,
      class_type_name: s.class_types?.name ?? null,
      class_type_color: s.class_types?.color ?? null,
      tier: showTier ? tierOf(s.guarantee_tier, s.flex) : undefined,
      minimum: showTier ? (s.minimum_bookings ?? flexMin) : null,
    }));
    return (
      <AppShell {...shell} title="Recurring classes"
                actions={
                  <>
                    {endedToggle}
                    <ViewTabs view={view} />
                    <Link href="/series/new"
                          className="inline-flex items-center rounded bg-ink px-3.5 py-2
                                     text-[13px] font-medium leading-[18px] text-paper hover:bg-ink-2">
                      Add a series
                    </Link>
                  </>
                }>
        <p className="mb-5 max-w-[62ch] text-[13px] leading-[20px] text-ink-2">
          Your standing week — what the timetable repeats, not what is happening on
          any particular day. The{" "}
          <Link href="/schedule" className="text-lime-text underline underline-offset-4">schedule</Link>{" "}
          answers that, with instructors and bookings on it.
        </p>
        {filters}
        <SeriesGrid
          series={forGrid}
          weekStartsOn={settings?.week_starts_on ?? 1}
          today={today}
          hoursFrom={hoursFrom}
          hoursTo={hoursTo}
          filterLabel={filterLabel}
        />
      </AppShell>
    );
  }

  return (
    <SetupShell
      shell={shell}
      title="Recurring classes"
      blurb="Your standing timetable. A series materialises twelve months of classes and keeps
             itself topped up every night, so a member can always book a month ahead.
             One-off classes are added from the schedule instead."
      tabs={<>{endedToggle}<ViewTabs view={view} /></>}
      belowBlurb={<>{summary}{filters}</>}
      newHref="/series/new" newLabel="Add a series" count={live.length}
      empty={filterLabel
        ? "No series match this filter."
        : "No recurring classes yet — this is where a studio's week comes from."}
      archived={
        <ArchivedSection noun="series" count={archived.length}>
          {archived.map((s) => (
            <SetupRow key={s.id} href={`/series/${s.id}`} name={s.name}
                      meta={meta(s)} state="archived"
                      mark={tierBits(s).mark} markLabel={tierBits(s).markLabel} />
          ))}
        </ArchivedSection>
      }
    >
      {live.map((s) => (
        <SetupRow key={s.id} href={`/series/${s.id}`} name={s.name}
                  meta={meta(s)}
                  mark={tierBits(s).mark} markLabel={tierBits(s).markLabel}
                  right={s.instructor_id ? undefined : "open"} />
      ))}
      {!hideEnded && ended.map((s) => (
        <SetupRow key={s.id} href={`/series/${s.id}`} name={s.name}
                  meta={meta(s)} state="ended"
                  mark={tierBits(s).mark} markLabel={tierBits(s).markLabel} />
      ))}
    </SetupShell>
  );
}
