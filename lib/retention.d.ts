export function freeStageWord(stage: string | null | undefined): string;
export function methodWord(method: string | null | undefined): string;
export function outcomeClause(outcome: string | null | undefined, outcomeDays: number | null | undefined): string | null;
export function outcomeLine(args: {
  method?: string | null;
  contactedAt?: string | number | null;
  outcome?: string | null;
  outcomeDays?: number | null;
  now?: number;
}): string | null;
export function stateLine(
  s: {
    plan_state?: string | null;
    free_stage?: string | null;
    health_band?: string | null;
    health_reason?: string | null;
    current_plan_name?: string | null;
    expires_on?: string | null;
    days_since?: number | null;
    last_contact_at?: string | null;
  } | null | undefined,
  opts?: { daysAgo?: number | null },
): string;
export const SNOOZE_DAYS: number[];
export function snoozeLabel(days: number): string;
