export type CheckinNoticeKind = "open" | "waiver" | "not_open" | "closed" | "none";
export type CheckinNoticeBooking = { name: string; startsAt: number; endsAt: number | null };
export declare function checkinNotice(args: {
  booking: CheckinNoticeBooking | null;
  now: number;
  opensBefore: number;
  closesAfter: number;
  waiverOk: boolean;
  fmt: (ms: number) => string;
}): { kind: CheckinNoticeKind; text: string | null };
