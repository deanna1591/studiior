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
export type SlotCoach = { id: string; replaces: boolean };
export type Slot = { start: string; coaches: SlotCoach[] };
export function mergeSlots(rows: { starts_at: string; coach_ids: string[] | null; replaces_occurrence_id: string | null }[] | null | undefined): Slot[];
export function slotsForCoach(slots: Slot[], coachId: string | null): Slot[];
export function coachStep(slot: Slot | null | undefined): { skip: boolean; coachId: string | null; choices: string[] };
export function slotReplaces(slot: Slot | null | undefined, coachId?: string | null): boolean;
