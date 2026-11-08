export type PostClass = { time: string; name: string; coach: string | null; tier: string };
export type PostDay = { date: string; label: string; count: number; classes: PostClass[] };
export type PostData = {
  studio_name: string;
  logo_url: string | null;
  time_zone: string;
  time_format: string;
  footer_line: string;
  hashtags: string | null;
  flex_min: number;
  days: PostDay[];
};
export type PostMode = "day" | "week" | "month";
export type PostFormat = "square" | "story";
export type MonthCell = { date: string; label: string; count: number; first: string[]; more: number };

export declare const MODES: PostMode[];
export declare const FORMATS: PostFormat[];
export declare function defaultDate(mode: PostMode, todayIso: string): string;
export declare function rangeFor(mode: PostMode, isoDate: string): { from: string; to: string };
export declare function coreOnlyDefault(flexMin: number): boolean;
export declare function filterDays(days: PostDay[], coreOnly: boolean): PostDay[];
export declare function classLine(c: PostClass): string;
export declare function captionText(data: { days?: PostDay[]; hashtags?: string | null }): string;
export declare function monthCells(days: PostDay[], limit?: number): MonthCell[];
export declare function totalClasses(days: PostDay[]): number;
