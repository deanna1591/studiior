export interface StatementRow {
  at: string;
  kind: string;
  title: string;
  detail: string | null;
  credit_delta: number | null;
  balance_after: number | null;
  amount_cents: number | null;
  currency?: string | null;
  occurrence_id: string | null;
  booking_id: string | null;
  membership_id: string | null;
  plan_name?: string | null;
  due_cents?: number | null;
  is_free_first?: boolean | null;
}
export function isMoneyRow(r: Pick<StatementRow, "credit_delta" | "amount_cents">): boolean;
export function moneyLine(row: StatementRow, money?: (cents: number) => string): string | null;
export function filterStatement<T extends StatementRow>(rows: T[], which: "all" | "classes" | "credits"): T[];
export function groupByMonth<T extends StatementRow>(rows: T[], monthLabel: (at: string) => string): { label: string; items: T[] }[];
export function withRunningBalance<T extends StatementRow>(rowsNewestFirst: T[]): T[];
