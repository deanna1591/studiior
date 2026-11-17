export function conditionLabels(conditions: Record<string, unknown> | null | undefined): string[];
export function cadenceLine(a: { cadence_weeks?: number; max_weekly?: number | null; monthly_mode?: string } | null | undefined): string;
export function quietBlocked(lastMs: number | null, nowMs: number, days?: number): boolean;
