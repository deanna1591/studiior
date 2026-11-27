export type PostClass = { time: string; end?: string | null; name: string; coach: string | null; tier: string; spots_left?: number; needs?: number | null };
export type PostDay = { date: string; label: string; count: number; classes: PostClass[] };
export type PostData = {
  studio_name: string;
  logo_url: string | null;
  time_zone: string;
  time_format: string;
  footer_line: string;
  hashtags: string | null;
  flex_min: number;
  coach_id: string | null;
  coach_first: string | null;
  coach_photo: string | null;
  days: PostDay[];
};
export type PostStyle = "guest_check" | "times" | "invitation" | "lock_screen" | "notes" | "receipt" | "timeline" | "retro" | "coach";
export type PostMode = "day" | "week" | "month";
export type PostFormat = "square" | "story";
export type MonthGridCell = { date: string | null; day: number | null; count: number; core: boolean; blank: boolean };

export declare const MODES: PostMode[];
export declare const FORMATS: PostFormat[];
export declare function defaultDate(mode: PostMode, todayIso: string): string;
export declare function rangeFor(mode: PostMode, isoDate: string): { from: string; to: string };
export declare function coreOnlyDefault(flexMin: number): boolean;
export declare function filterDays(days: PostDay[], coreOnly: boolean): PostDay[];
export declare function spotsLabel(n: number | null | undefined): string;
export declare function classLine(c: PostClass, opts?: { showSpots?: boolean }): string;
export declare function captionText(data: { days?: PostDay[]; hashtags?: string | null; coachFirst?: string | null; mode?: PostMode; showSpots?: boolean }): string;
export declare function monthGrid(days: PostDay[], monthStart: string): MonthGridCell[][];
export declare function totalClasses(days: PostDay[]): number;

export type FitPage = { days: PostDay[]; part: number; parts: number; scale: number };
export type FitPlan = { pages: FitPage[] };
export declare const FIT: {
  budget: number; floor: number; steps: number[];
  dayRow: number; weekHeader: number; weekClass: number; weekGap: number;
};
export declare function bodyHeight(days: PostDay[], mode: PostMode): number;
export declare function fitScale(h1: number): { scale: number; fits: boolean };
export declare function splitForSquare(days: PostDay[], mode: PostMode): PostDay[][];
export declare function fitPlan(args: { days: PostDay[]; mode: PostMode; format: PostFormat }): FitPlan;
export declare function pushSpec<T>(stack: T[], spec: T): T[];
export declare function undoStack<T>(stack: T[]): { stack: T[]; current: T | null };
export declare function canUndo<T>(stack: T[]): boolean;

// --- Editorial styles (amendment) -------------------------------------------
export declare const POST_STYLES: PostStyle[];
export declare const STYLE_LABELS: Record<PostStyle, string>;
export declare function headlineParts(args: { mode: PostMode; weekday?: string; monthName?: string; coachFirst?: string | null; isToday?: boolean; isCurrentMonth?: boolean }): { lead: string; accent: string };
export declare function shortName(name: string): string;
export declare function receiptNo(isoDate: string): string;
export declare function titleCase(s: string): string;
export declare function stripLeadingZero(t: string): string;
export declare const STYLE_FIT: Record<PostStyle, {
  dayBudget: number; dayRow: number; floor: number; steps: number[];
  weekKind: "classes" | "grid" | "none"; weekBudget?: number; gridRow?: number;
  weekHeadingRow?: number; weekClassRow?: number;
  story?: { dayBudget: number; dayRow: number; weekBudget?: number; weekHeadingRow?: number; weekClassRow?: number };
}>;
// --- Decision 93 (d): the five v5 styles ------------------------------------
export declare const V5_STYLES: PostStyle[];
export declare function styleModes(style: PostStyle): PostMode[];
export declare function styleNeedsCoach(style: PostStyle): boolean;
export declare function classIcon(name: string): "flame" | "bolt" | "leaf" | "sparkle" | "sun";
export declare function classFormat(name: string): string;
export declare function clockMinutes(t: string | null | undefined): number | null;
export declare function diaryLine(day: PostDay | null | undefined, opts?: { isLast?: boolean }): string;
export declare function bookingLine(d?: { mode?: string | null; time?: string | null; hours?: number | null }): string | null;
export declare function flexReminder(flexMin: number, d?: { mode?: string | null; time?: string | null; hours?: number | null }): string | null;
export declare function tierChip(c: PostClass | null | undefined, flexMin: number): { text: string; kind: "core" | "flex" };
export declare function logoFallback(logo: string | null | undefined, studioName: string): string | null;
export declare function coachPhotoBox(format: PostFormat): { objectFit: string; objectPosition: string; left: number; top: number; width: number; height: number };
export declare function shortClass(name: string): string;
export declare function retroDate(isoDate: string): string;
export declare function weekStrip(isoDate: string): { dow: string; day: number; on: boolean }[];
export declare function stepFit(h: number, budget: number, steps: number[], floor: number): { scale: number; fits: boolean };
export declare function editorialPlan(args: { days: PostDay[]; mode: PostMode; format: PostFormat; style: PostStyle }): FitPlan;
export type WeekRow = { icon: string; time: string; name: string; coach: string; spots_left?: number; needs?: number | null };
export type WeekGroup = { label: string; classes: WeekRow[] };
export declare function weekRows(days: PostDay[], opts?: { coachMode?: boolean }): WeekGroup[];
export declare function anyFlex(days: PostDay[]): boolean;
export function flexLegend(flexMin: number | null | undefined): string | null;
export function needsNote(c: { needs?: number | null } | null | undefined): string | null;
