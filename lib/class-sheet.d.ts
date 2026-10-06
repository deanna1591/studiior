import type { ClassButtonInput, ClassButtonState } from "./class-button";
export interface ClassSheetInput extends ClassButtonInput {
  full?: boolean;
  waitlistEnabled?: boolean;
  freeFirstEligible?: boolean;
}
export type SheetAction = "checkin" | "cancel" | "leave" | "waitlist" | "book" | "bookfree";
export function classSheetView(input?: ClassSheetInput): {
  state: ClassButtonState;
  actions: SheetAction[];
  hideCapacity: boolean;
};
