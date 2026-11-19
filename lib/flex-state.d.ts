export function flexStateChip(a: {
  flex: boolean; status: string; cancellationCause?: string | null; committed: boolean;
  reachedMinimum: boolean; paid: number; unpaid: number; minimum: number | null;
}): { kind: "count" | "running" | "not_running" | "none"; text: string };
export function cancellationCauseLabel(cause: string | null | undefined): string | null;
