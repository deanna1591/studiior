export type FreeStage = "booked" | "taken" | "missed" | null;
type BookingLite = { paymentSource?: string; status?: string; startsAt?: string | number };
export function freeStage(bookings?: BookingLite[]): FreeStage;
export function defaultSortMode(members?: { lifetime_visits?: number | null }[]): "attention" | "newest";
