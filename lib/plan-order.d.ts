export interface OrderablePlan {
  featured?: boolean | null;
  sort_order?: number | null;
  status?: string | null;
}
export function sortPlans<T extends OrderablePlan>(plans: T[]): T[];
export function badgeOk(badge: string | null | undefined): boolean;
export function clampBadge(badge: string | null | undefined): string | null;
