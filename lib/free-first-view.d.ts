type FreeClass = { occurrence_id: string; free_bookable: boolean };
export function freeEligibleSet(freeList?: FreeClass[]): Set<string>;
export function whichView(input: { freeFirstEligible?: boolean; eligibleCount?: number; showAll?: boolean }): "picker" | "timetable";
export function nearestEligibleDay(dayKeys?: string[], wanted?: string | null): string | null;
export function trialsMarker(
  freeFirst?: { override?: "open" | "closed" | null; rulesOpen?: boolean } | null,
): "trials" | "no_trials" | null;
