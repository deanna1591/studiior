export function flexStateChip(a: {
  flex: boolean; status: string; cancellationCause?: string | null; committed: boolean;
  reachedMinimum: boolean; paid: number; unpaid: number; minimum: number | null;
}): { kind: "count" | "running" | "not_running" | "none"; text: string };
export function cancellationCauseLabel(cause: string | null | undefined): string | null;
export function memberFlexChip(a: {
  tier: string | null | undefined; paid: number | null | undefined; min: number | null | undefined;
  reached?: boolean | null; committed?: boolean | null; isPrivate?: boolean; hidden?: boolean; long?: boolean;
}): { label: string; tone: "core" | "running" | "needs" | "first" } | null;
