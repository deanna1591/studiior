export type TimeFormat = "24h" | "12h";
export function fmtClock(
  value: string | Date | number,
  timeZone: string,
  format?: TimeFormat,
): string;
