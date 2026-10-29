export function classTagText(props: {
  tier: string | null;
  flex?: boolean;
  committed?: boolean;
  cancelled?: boolean;
  flexDeadlineShort?: string | null;
  guaranteesEnabled?: boolean;
  flexEnabled?: boolean;
}): { show: boolean; text: string; isFlex: boolean };
