export interface FCOccurrence {
  flex: boolean;
  guaranteeTier?: string | null;
  minimumBookings?: number | null;
  committedAt?: string | null;
  status: string;
  startsMs: number;
  bookedCount: number;
}
export interface FCSettings {
  guaranteesEnabled: boolean;
  flexEnabled: boolean;
  coreMin: number;
  flexMin: number;
  nowMs: number;
}
export function canForceCommit(occ: FCOccurrence, settings: FCSettings): "none" | "run_anyway";
export function forceCommitMinimum(occ: FCOccurrence, settings: FCSettings): number;
