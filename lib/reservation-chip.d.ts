export type ReservationChip = { text: string; tone: "ok" | "muted" | "warn" };
export function reservationChip(
  s: { state: string | null; feeCents?: number; currency?: string; deadlineLabel?: string } | null | undefined,
  fmtMoney: (cents: number, currency: string) => string,
): ReservationChip | null;
export function freeSeatsLine(c: { n: number; paid: number; due: number; waived: number }): string | null;
