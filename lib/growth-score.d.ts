export const RECENT_WEEKS: number;
export const HISTORY_WEEKS: number;

export interface SlotWeek {
  booked: number;
  capacity: number;
  attended: number;
  waitlist: number;
  noShow: number;
  lateCancel: number;
}

export function clampFrac(booked: number, capacity: number): number;
export function occScore(w: SlotWeek): number;
export function weightFor(idx: number): number;
export function slotScore(weeks: SlotWeek[]): number;
export function hasEnoughHistory(n: number): boolean;
export function collectingLabel(n: number): string;
export function qualifies(weeks: SlotWeek[], flexMin: number): boolean;
