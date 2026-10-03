/**
 * Decision 54 — the small core/flex tag on every instructor-facing class row.
 *
 * Instructors see which classes are flex and WHEN a flex class is decided; they
 * never see headcount-to-minimum wording ("needs 3 more"). Members and the
 * website never see this tag at all (Decision 21) — it lives only in the
 * instructor portal, so it is a portal component, not a member one.
 *
 *   core                         — a guaranteed class
 *   flex · decided by 8:00 PM Mon — a flex class still waiting on its deadline
 *   flex · confirmed             — a flex class that reached its minimum
 *   flex                         — a flex class with no live deadline (e.g. off)
 */
export function classTagText({
  tier, flex, committed = false, cancelled = false, flexDeadlineShort = null,
}: {
  tier: string | null; flex?: boolean; committed?: boolean;
  cancelled?: boolean; flexDeadlineShort?: string | null;
}): { text: string; isFlex: boolean } {
  const isFlex = tier === "flex" || flex === true;
  if (!isFlex) return { text: "core", isFlex: false };
  if (cancelled) return { text: "flex", isFlex: true };
  if (committed) return { text: "flex · confirmed", isFlex: true };
  if (flexDeadlineShort) return { text: `flex · decided by ${flexDeadlineShort}`, isFlex: true };
  return { text: "flex", isFlex: true };
}

export default function ClassTag(props: {
  tier: string | null; flex?: boolean; committed?: boolean;
  cancelled?: boolean; flexDeadlineShort?: string | null;
}) {
  const { text, isFlex } = classTagText(props);
  return (
    <span
      className="inline-flex shrink-0 items-center rounded-full px-2 py-0.5 text-[11px] font-medium leading-none"
      style={isFlex
        ? { background: "var(--accent-chip)", color: "var(--lime-text)" }
        : { background: "var(--paper)", color: "var(--ink-3)" }}>
      {text}
    </span>
  );
}
