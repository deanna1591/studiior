export type DeskPayMode = "earned" | "first_visit_only" | "staff_only";
export const DESK_PAY_MODES: { value: DeskPayMode; label: string; help: string }[];
export function normaliseDeskPayMode(v: unknown): DeskPayMode;
