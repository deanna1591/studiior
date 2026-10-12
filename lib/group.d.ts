// Types for the plain-ESM lib/group.mjs (Decision 76b).

export type GroupEmailProblem = {
  ok: false;
  reason: "wrong_count" | "blank" | "duplicate" | "is_host";
  index?: number;
  email?: string;
  expected?: number;
  got?: number;
};

export function validateGroupEmails(
  emails: string[],
  hostEmail: string,
  groupSize: number,
): { ok: true } | GroupEmailProblem;

export type GroupClass = {
  occurrence_id?: string;
  id?: string;
  starts_at: string;
  status?: string;
  capacity: number;
  booked_count: number;
  seats_held?: number;
};

export function eligibleGroupClasses<T extends GroupClass>(
  classes: T[],
  groupSize: number,
  nowMs: number,
): T[];
