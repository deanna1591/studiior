// Types for the plain-ESM lib/closure-notice.mjs (Decision 77b).

export function resumeDefault(endsOn: string): string;
export function beyondHorizon(resumesOn: string, today: string, horizonDays: number): boolean;
export function longDate(iso: string): string;
export function previewSystemBlock(input: {
  resumesOn: string;
  sampleCancelled?: string[];
}): { html: string; text: string };
