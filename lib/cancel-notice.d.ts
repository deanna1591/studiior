export type SeatKind = "free" | "credit" | "unlimited" | "drop_in";

export function seatKindOf(x: {
  paymentSource?: string | null;
  creditEntryId?: string | null;
  isFreeBooking?: boolean;
}): SeatKind;

export function cancelNotice(x: {
  startsMs: number;
  cutoffMinutes: number;
  nowMs: number;
  seatKind: SeatKind;
  fmtTime: (ms: number) => string;
  fmtDay: (ms: number) => string;
}): { phase: "before" | "after" | "started"; line: string };

export function cancelResult(x: {
  seatKind: SeatKind;
  late: boolean;
  creditReturned: boolean;
}): string;
