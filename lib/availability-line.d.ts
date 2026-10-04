// Types for the plain-ESM lib/availability-line.mjs.

export type SubmissionStatus =
  | "submitted" | "approved" | "changes_requested" | "none" | null | undefined;

export type StandingCoverage = { endsOn: string | null } | null;

export interface AvailabilityLineInput {
  submissionStatus: SubmissionStatus;
  monthLabel: string;
  standing: StandingCoverage;
  instructorId: string;
}

/** The "Availability: …" line + where it links. Decision 46 follow-up. */
export function availabilityLine(
  input: AvailabilityLineInput,
): { text: string; href: string; linkLabel: string };

/** The review-page note beside a not-sent instructor who has a standing pattern. */
export function standingNote(standing: StandingCoverage): string;
