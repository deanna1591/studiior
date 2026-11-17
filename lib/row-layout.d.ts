export function shouldStackAction(
  actionLabel: string | null | undefined,
  state?: { booked?: boolean; held?: boolean; waiting?: boolean },
): boolean;
