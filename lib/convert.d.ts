// Types for lib/convert.mjs (Decision 78).
export function windowEndMs(startMs: number, days: number): number;
export function windowActive(startMs: number | null, endMs: number, nowMs: number, hasMembership: boolean): boolean;
export function quietShift(localHour: number): { hour: number; dayDelta: number };
export function daysSince(classDate: string, nowDate: string): number;
export function dateRuleDue(
  rule: "before_class" | "missed_you" | "day3" | "day7" | string,
  delta: number,
): boolean;
export function afterClassDue(endMs: number, nowMs: number): boolean;
export function viberText(firstName: string | null | undefined, studioName: string, offerName: string | null | undefined): string;
export const CONVERT_TEMPLATES: string[];
