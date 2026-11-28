export type SoldState = { plan_id?: string; max_sold: number | null; sold: number | null; sold_out: boolean };
export const SOLD_OUT_CHIP: string;
export const SOLD_OUT_SENTENCE: string;
export function isSoldOut(state: Partial<SoldState> | null | undefined): boolean;
export function soldLine(state: Partial<SoldState> | null | undefined): string | null;
export function offlineBuyLine(staffOnly: boolean): string;
