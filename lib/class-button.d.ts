export type ClassButtonInput = {
  bookingStatus?: string | null;
  flexPending?: boolean;
  checkedIn?: boolean;
  cancelled?: boolean;
  startsMs: number;
  endsMs?: number | null;
  opensBeforeMin?: number;
  closesAfterMin?: number;
  nowMs?: number;
};
export type ClassButtonState =
  | "book" | "reserved" | "waiting_confirmation"
  | "checkin" | "checked_in" | "waitlisted" | "cancelled";
export function classButtonState(input: ClassButtonInput): ClassButtonState;
