export const FREE_PICKER_HEADING: string;
export function freePickerSubline(opts?: {
  coreOnly?: boolean;
  reservationFeeLabel?: string | null;
}): string;
export const FREE_PICKER_BUTTON: string;
export function freePickerTier(
  c: { occ_flex?: boolean | null; occ_paid_count?: number | null; occ_min?: number | null;
       occ_reached_minimum?: boolean | null; occ_committed?: boolean | null },
  opts?: { guaranteesEnabled?: boolean },
): {
  alwaysRuns: boolean;
  flexState: null | { tier: "flex"; paid: number; min: number | null; reached: boolean; committed: boolean };
};
