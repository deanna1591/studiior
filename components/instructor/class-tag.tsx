import { classTagText } from "@/lib/class-tag";

/**
 * Decision 54 (+ guarantees/flex visibility) — the small core/flex tag on every
 * instructor-facing class row.
 *
 * Instructors see which classes are flex and WHEN a flex class is decided; they
 * never see headcount-to-minimum wording ("needs 3 more"). Members and the
 * website never see this tag at all (Decision 21) — it lives only in the
 * instructor portal, so it is a portal component, not a member one.
 *
 * The rule (both switches off = no tag; only the on tier is tagged; effective
 * tier, not raw) lives in lib/class-tag so it is node-tested; this renders it.
 */
export { classTagText };

export default function ClassTag(props: {
  tier: string | null; flex?: boolean; committed?: boolean;
  cancelled?: boolean; flexDeadlineShort?: string | null;
  guaranteesEnabled?: boolean; flexEnabled?: boolean;
}) {
  const { show, text, isFlex } = classTagText(props);
  if (!show) return null;
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
