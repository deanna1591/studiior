export type Gap = { from: string; to: string; starts: string[] };
export function groupGaps(starts: string[], stepMin?: number): Gap[];
export function localWeekday(iso: string, timeZone: string): number;
export function localDate(iso: string, timeZone: string): string;
export function gapsPerWeekday(
  starts: string[], timeZone: string, stepMin?: number,
): Record<"Mon" | "Tue" | "Wed" | "Thu" | "Fri" | "Sat" | "Sun", number>;
export function cancelIsOnTime(startsMs: number, leadHours: number, nowMs: number): boolean;
export function cancelNoticeLine(a: {
  startsMs: number; leadHours: number; nowMs: number; fmt: (ms: number) => string;
}): string;
export const PRIVATE_REASONS: Record<string, string>;
export function privateReasonSentence(reason: string | null | undefined): string;
export function vatSplit(totalCents: number): { netCents: number; vatCents: number };
export const REPLACES_LABEL: string;
export function slotLabel(replacesOccurrenceId: string | null | undefined): string | null;
export function replaceAllowed(a: { empty: boolean; targeted?: boolean; tier: string; hoursUntilStart: number; windowHours?: number | null }): boolean;
