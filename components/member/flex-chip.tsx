import { memberFlexChip } from "@/lib/flex-state";

/**
 * Decision 22(f): the one chip for a class's state on member screens. "Always
 * runs" (core), "Running" (green), "Needs {n} more" (the invitation, ink on the
 * accent chip) or "Be the first" (quiet). The wording comes from
 * memberFlexChip, so every surface says the same thing.
 */
export type FlexChipInput = {
  tier: string | null | undefined; paid?: number | null; min?: number | null;
  reached?: boolean | null; committed?: boolean | null; isPrivate?: boolean; hidden?: boolean;
};

const STYLE: Record<string, React.CSSProperties> = {
  core:    { background: "var(--surface)", color: "var(--lime-text)" },
  running: { background: "var(--run-tint)", color: "var(--run-ink)" },
  needs:   { background: "var(--accent-chip)", color: "var(--ink)" },
  first:   { background: "var(--surface)", color: "var(--ink-2)", boxShadow: "inset 0 0 0 1px var(--line)" },
};

export function FlexChip({ state, className = "" }: { state: FlexChipInput; className?: string }) {
  const chip = memberFlexChip({
    tier: state.tier, paid: state.paid ?? 0, min: state.min ?? 0,
    reached: state.reached, committed: state.committed,
    isPrivate: state.isPrivate, hidden: state.hidden,
  });
  if (!chip) return null;
  return (
    <span className={`m-micro whitespace-nowrap rounded-full px-2 py-0.5 font-semibold ${className}`}
          style={STYLE[chip.tone]}>
      {chip.label}
    </span>
  );
}
