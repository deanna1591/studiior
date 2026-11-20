export function memberFeeCents(s: { reservationFeeCents?: number | null; feeWaived?: boolean | null }): number;
export function freeClassRoute(s: { reservationFeeCents?: number | null; feeWaived?: boolean | null }): "free" | "reserve";
