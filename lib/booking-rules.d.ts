export function clampInt(raw: unknown, fallback: number): number;
export function cutoffMinutes(hoursRaw: unknown, minutesRaw: unknown): number;
export function cutoffParts(total: number): { hours: number; minutes: number };
export function cutoffLabel(total: number): string;
