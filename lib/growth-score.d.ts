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
export function metStreak(weeks: { booked?: number }[], flexMin: number): number;
export function emptyStreak(weeks: { booked?: number }[]): number;
export function numberWord(n: number): string;
export function suggestionLine(a: {
  action: "make_core" | "make_flex" | null; metStreak: number; emptyStreak: number;
  met4: number; lastBooked: number; flexMin: number;
}): string | null;
export function weekBudget(coreNow: number, budget: number,
  makeCore: { id: string; score: number; classes: number }[]): { id: string; wouldHold: number; overBudget: boolean }[];
