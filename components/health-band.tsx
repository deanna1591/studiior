/**
 * The Member Health band — Decision 14.
 *
 * The one place in this app that spends colour. Three judgements — lime,
 * amber, coral — and two non-judgements, `new` and `insufficient_history`, in
 * grey, because "we do not know yet" must not look like a verdict.
 *
 * The reason is never truncated. A band without its reason is a score, and
 * Decision 14 exists to argue against scores: "was coming twice a week, hasn't
 * been in 16 days" is something an owner can act on before lunch, and
 * "retention risk" is not.
 *
 * Two things here were built the obvious way first and then rebuilt:
 *
 *  - Every band as a full saturated fill. On a real list most members are
 *    healthy, so the screen came out two-thirds lime and the signal vanished.
 *    Then, sorted by severity, it came out a wall of coral instead. Saturation
 *    now sits on the label only, and the sentence gets a wash — strong at any
 *    count, rather than strong at one and deafening at twelve.
 *  - A fallback reason for healthy. Decision 14 gives a reason to every band
 *    *except* healthy, so there was nothing true to write; it now renders as a
 *    chip with nothing after it.
 */
export type Band = "healthy" | "drifting" | "at_risk" | "new" | "insufficient_history";

const BANDS: Record<Band, {
  label: string; fill: string; wash: string; rule: string; text: string;
}> = {
  healthy: {
    label: "Healthy", fill: "bg-lime", wash: "bg-lime-tint",
    rule: "var(--lime-text)", text: "text-ink",
  },
  drifting: {
    label: "Drifting", fill: "bg-amber", wash: "bg-amber-tint",
    rule: "rgba(20,23,14,0.32)", text: "text-ink",
  },
  at_risk: {
    label: "At risk", fill: "bg-coral-fill", wash: "bg-coral-tint",
    rule: "var(--coral)", text: "text-ink",
  },
  new: {
    label: "New", fill: "bg-line", wash: "bg-paper",
    rule: "var(--ink-3)", text: "text-ink-2",
  },
  insufficient_history: {
    label: "Too early", fill: "bg-line", wash: "bg-paper",
    rule: "var(--ink-3)", text: "text-ink-2",
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

/** The chip alone — roster lines, and healthy members in a list. */
export function HealthChip({ band }: { band: Band }) {
  const b = BANDS[band];
  return (
    <span
      className={`section-label inline-flex shrink-0 items-center rounded-sm px-1.5 py-0.5 ${b.fill} ${b.text}`}
      style={{ fontSize: 11, letterSpacing: "0.07em" }}
    >
      {b.label}
    </span>
  );
}

/**
 * Label plus reason. The signature element.
 *
 * One size only. A larger variant for a member detail screen was written here
 * before that screen existed, and an unrendered branch is a branch nobody has
 * looked at — it comes back when there is something to put it on.
 */
export function HealthBand({ band, reason }: { band: Band; reason: string | null | undefined }) {
  const b = BANDS[band];
  if (!reason) return <HealthChip band={band} />;
  return (
    <div className="flex items-stretch overflow-hidden rounded-sm">
      <div className="w-[3px] shrink-0" style={{ background: b.rule }} aria-hidden />
      <div className={`flex min-w-0 flex-1 items-baseline gap-2.5 px-2.5 py-1.5 ${b.wash}`}>
        <span
          className={`section-label shrink-0 rounded-sm px-1.5 py-0.5 ${b.fill} ${b.text}`}
          style={{ fontSize: 11, letterSpacing: "0.07em" }}
        >
          {b.label}
        </span>
        <p className="min-w-0 text-[13px] leading-[18px] text-ink">{reason}</p>
      </div>
    </div>
  );
}
