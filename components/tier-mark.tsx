import type { ReactNode } from "react";

export type Tier = "core" | "flex" | "always";

/**
 * WHICH TIER A SERIES IS, and the order is NOT the SQL coalesce — for a reason
 * that took driving the screen to find.
 *
 * `occurrence_guarantee_run()` walks occurrence column, occurrence boolean,
 * series column, series boolean, then core. A series row has no occurrence, so
 * the naive mirror is `coalesce(series column, series boolean, 'core')` — and
 * that is WRONG, because `class_series.guarantee_tier` is NOT NULL with a
 * default of 'core'. The column always answers, so the series boolean is
 * unreachable and a mirror built that way reports 'core' for every flex series
 * a studio created with Decision 21's writer.
 *
 * And there are two writers, still. `set_series_flex()` sets `flex` and
 * `minimum_bookings` and never touches the column; `set_series_guarantee()` sets
 * the column. The first is what the flex suite's fixtures use and what any
 * studio running Decision 21 before Decision 22 landed has on disk.
 *
 * What saves those rows in the database is that `set_series_flex()` propagates
 * the boolean DOWN to the occurrences, so the engine reaches them at the second
 * arm of the walk — the occurrence's own `flex`. So the honest question for a
 * series row is not "what does the coalesce say about this row" but "what will
 * its classes be", and the answer is: a true boolean means flex, whatever the
 * column was left at.
 *
 * The column is read for everything else, which is how 'always' and an
 * explicitly-set 'flex' arrive.
 */
export function tierOf(guaranteeTier: string | null, flex: boolean | null): Tier {
  if (flex) return "flex";
  return (guaranteeTier as Tier | null) ?? "core";
}

/**
 * ● core · ○ flex · ◆ always.
 *
 * SHAPE, NOT COLOUR, and that is the whole design. On the series grid the colour
 * is the studio's own `class_types.color`; on the schedule calendar it is
 * staffing — amber for nobody teaching, coral for nobody teaching a class people
 * have booked. Tier cannot take either of those over: a studio needs both facts
 * at once, and a green Sculpt block turning amber because it is flex would tell
 * them something false.
 *
 * NOT A DASHED EDGE EITHER. The calendar already spends that on "a flex class
 * still waiting on its deadline", which is a temporary state — it clears the
 * moment the class commits. The tier is permanent. Conflating them would mean a
 * committed flex class looked exactly like a core one, which is the gap this
 * exists to close.
 *
 * NOT OPACITY. This project has had to undo opacity on text twice — the series
 * grid's ended blocks at 2.27:1 and the login sub-line at 3.61 — because fading
 * a colour that was measured at full strength is a contrast change wearing the
 * clothes of a styling choice.
 *
 * So it is a glyph, in a neutral ink step, measured like any other text.
 */
export function TierMark({ tier, effective, minimum, className = "" }: {
  tier: Tier;
  /**
   * What the class will actually DO, when that differs from what it is.
   *
   * `occurrence_guarantee()` demotes a tier whose switch is off to 'always' —
   * correctly, because with core evaluation off a core class runs regardless.
   * The MARK shows the configured tier, because that is the per-class fact a
   * studio is scanning a timetable for and the only one the series list can
   * know; the demotion is studio-wide and would mark every core class the same.
   * But it is not swallowed either: it is what the mark says on hover.
   */
  effective?: Tier | null;
  minimum?: number | null;
  className?: string;
}) {
  const glyph = tier === "flex" ? "○" : tier === "always" ? "◆" : "●";
  const base = tier === "flex"
    ? `Flex class${minimum != null ? ` — runs with ${minimum} or more` : ""}`
    : tier === "always" ? "Always runs" : "Core class";
  const demoted = effective === "always" && tier !== "always";
  const label = demoted
    ? `${base}. ${tier === "flex" ? "Flex" : "Core"} evaluation is switched off for this studio, so it runs regardless.`
    : base;
  return (
    <span aria-hidden className={`tier-mark ${className}`} title={label}>{glyph}</span>
  );
}

/**
 * The tier as a phrase, with the minimum beside a flex one — because that is the
 * number that decides whether it runs at all, and a studio reading "flex" alone
 * still has to open the series to find it.
 *
 * The minimum falls back to the studio's own `flex_min_bookings` exactly as
 * `occurrence_guarantee_run()` does, so a series that has not set one shows what
 * will actually be required of it rather than nothing.
 */
export function TierLabel({ tier, minimum, studioFlexMin, studioCoreMin }: {
  tier: Tier; minimum: number | null;
  studioFlexMin: number; studioCoreMin: number;
}): ReactNode {
  if (tier === "always") return <>always runs</>;
  const n = minimum ?? (tier === "flex" ? studioFlexMin : studioCoreMin);
  if (tier === "flex") return <>flex · <span className="num">{n}</span>+</>;
  return <>core</>;
}

/**
 * The same phrase as a plain string, for the places that take text rather than
 * nodes — `SetupRow.meta` is one. Kept beside TierLabel deliberately: two
 * renderings of one fact, in one file, so they cannot drift apart in the way
 * this project keeps finding.
 */
export function tierPhrase(tier: Tier, minimum: number | null,
                           studioFlexMin: number, studioCoreMin: number): string {
  if (tier === "always") return "always runs";
  if (tier === "flex") return `flex · ${minimum ?? studioFlexMin}+`;
  return "core";
}

/** Screen-reader text, since the glyph itself is aria-hidden. */
export function tierWords(tier: Tier, minimum: number | null, studioFlexMin: number): string {
  if (tier === "always") return "Always runs";
  if (tier === "flex") return `Flex class, runs with ${minimum ?? studioFlexMin} or more`;
  return "Core class";
}
