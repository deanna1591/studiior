export type TierTintRow = {
  tier?: string | null;
  flex?: boolean | null;
  seriesTier?: string | null;
  seriesFlex?: boolean | null;
};
export const ALWAYS_RUNS_CHIP: string;
export function effectiveTier(row: TierTintRow): "core" | "flex" | "always";
export function isCore(row: TierTintRow): boolean;
export function showsAlwaysRuns(guaranteesEnabled: boolean, row: TierTintRow): boolean;
export function tierTintStyle(): { background: string };
export function alwaysRunsChipStyle(): { background: string; color: string };
