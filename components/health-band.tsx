/**
 * The Member Health band — Decision 14.
 *
 * The one place in this app that spends colour. Three judgements — lime, amber,
 * coral — and two non-judgements in grey, because "we do not know yet" must not
 * look like a verdict.
 *
 * The reason is never truncated. A band without its reason is a score, and
 * Decision 14 exists to argue against scores: "was coming twice a week, hasn't
 * been in 16 days" is something an owner can act on before lunch, and
 * "retention risk" is not.
 *
 * Three things here were built the obvious way first and then rebuilt:
 *
 *  - Every band as a full saturated fill. On a real list most members are
 *    healthy, so the screen came out two-thirds lime and the signal vanished.
 *    Sorted by severity it came out a wall of coral instead.
 *  - A fallback reason for healthy. Decision 14 gives a reason to every band
 *    *except* healthy, so there was nothing true to write.
 *  - The chip as a hard-cornered, tracked-out, fully saturated slab. That is
 *    the shape of an enum member, and twelve of them down a column read as a
 *    database column rather than as a remark about a person. It is now a pill:
 *    tinted fill, a dot carrying the colour, a hairline a step darker, and a
 *    2px shadow so it sits on the row instead of being printed onto it.
 */
export type Band = "healthy" | "drifting" | "at_risk" | "new" | "insufficient_history";

const BANDS: Record<Band, {
  label: string; fill: string; dot: string; edge: string; wash: string; rule: string;
}> = {
  healthy: {
    label: "Healthy",
    fill: "var(--lime-tint)", dot: "var(--lime-text)", edge: "var(--edge-lime)",
    wash: "bg-lime-tint", rule: "var(--lime-text)",
  },
  drifting: {
    label: "Drifting",
    fill: "var(--amber-tint)", dot: "var(--amber-deep)", edge: "var(--edge-amber)",
    wash: "bg-amber-tint", rule: "var(--amber-deep)",
  },
  at_risk: {
    label: "At risk",
    fill: "var(--coral-tint)", dot: "var(--coral)", edge: "var(--edge-coral)",
    wash: "bg-coral-tint", rule: "var(--coral)",
  },
  // Two different things that used to share a label. "New" is a real state
  // with a clock on it; "Not enough history" is the absence of a verdict, and
  // its dot is hollow to say so. "Too early" was neither — it read as though
  // the member had turned up too soon.
  new: {
    label: "New",
    fill: "var(--paper)", dot: "var(--ink-3)", edge: "var(--edge-neutral)",
    wash: "bg-paper", rule: "var(--ink-3)",
  },
  insufficient_history: {
    label: "Not enough history",
    fill: "var(--paper)", dot: "transparent", edge: "var(--edge-neutral)",
    wash: "bg-paper", rule: "var(--line-2)",
  },
};

export function bandOf(v: string | null | undefined): Band {
  return (v && v in BANDS ? v : "insufficient_history") as Band;
}

/**
 * Which bands earn the full-width band. Healthy has no reason to carry, so it
 * stays a chip and the bar is spent on the states that ask something of you.
 */
export function isLoud(band: Band): boolean {
  return band === "at_risk" || band === "drifting" || band === "new";
}

/**
 * The chip alone — roster lines, and healthy members in a list.
 *
 * `onWash` is for the hero, the one place the chip sits on a tinted ground.
 * Its own fill is that same tint, so on a wash it dissolves into the panel and
 * reads as text with a dot in front of it; there it takes the surface colour
 * instead and lifts off. Everywhere else the tint is what gives it a body.
 */
export function HealthChip({ band, onWash }: { band: Band; onWash?: boolean }) {
  const b = BANDS[band];
  const hollow = band === "insufficient_history";
  return (
    <span className="chip" style={{ background: onWash ? "var(--surface)" : b.fill, borderColor: b.edge }}>
      <span
        className="chip-dot"
        style={
          hollow
            ? { background: "transparent", boxShadow: `inset 0 0 0 1.5px var(--ink-3)` }
            : { background: b.dot }
        }
        aria-hidden
      />
      {b.label}
    </span>
  );
}

/** Label plus reason. The signature element. */
export function HealthBand({
  band, reason, size = "row",
}: {
  band: Band;
  reason: string | null | undefined;
  size?: "row" | "hero";
}) {
  const b = BANDS[band];
  const hero = size === "hero";
  if (!reason) return hero ? <HeroEmpty band={band} /> : <HealthChip band={band} />;
  return (
    <div className="flex items-stretch overflow-hidden rounded-sm">
      <div className="w-[3px] shrink-0" style={{ background: b.rule }} aria-hidden />
      {/* The hero keeps its wash — it is one statement at the top of a screen
          and can afford the ground. The row size does not: the chip is tinted
          the same colour, so a wash behind it left a pill dissolving into a
          bar, and twelve pale bars down a list is the slab problem again in a
          weaker shade. Rule, pill, sentence. */}
      <div className={`flex min-w-0 flex-1 ${hero ? `${b.wash} flex-col items-start gap-2 px-4 py-3.5` : "items-center gap-2.5 py-1 pl-2.5"}`}>
        <HealthChip band={band} onWash={hero} />
        <p className={`min-w-0 text-ink ${hero ? "text-[15px] leading-[22px]" : "text-[13px] leading-[18px]"}`}>
          {reason}
        </p>
      </div>
    </div>
  );
}

/**
 * The hero band for a member with no reason to carry — healthy, by Decision 14,
 * or one the signals cannot speak about yet. Saying so plainly beats both an
 * empty panel and an invented reassurance.
 */
function HeroEmpty({ band }: { band: Band }) {
  const b = BANDS[band];
  return (
    <div className="flex items-stretch overflow-hidden rounded-sm">
      <div className="w-[3px] shrink-0" style={{ background: b.rule }} aria-hidden />
      <div className={`flex flex-1 flex-col items-start gap-2 px-4 py-3.5 ${b.wash}`}>
        <HealthChip band={band} onWash />
        <p className="text-[15px] leading-[22px] text-ink">
          {band === "healthy"
            ? "Nothing to flag. They are coming at their own steady rhythm."
            : "Not enough of a pattern yet to say anything useful about this member."}
        </p>
      </div>
    </div>
  );
}
