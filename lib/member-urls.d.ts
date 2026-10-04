export function buyPath(planId: string): string;
export function buyUrl(memberOrigin: string, planId: string): string;
export function resolveMemberBase(
  dbValue: string | null | undefined,
  envValue: string | null | undefined,
  requestHost: string | null | undefined,
): string;
export function memberOriginFrom(base: string, slug: string): string;
