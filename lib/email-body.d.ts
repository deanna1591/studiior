// Types for the plain-ESM lib/email-body.mjs (Decision 77).

/** Render a composed email body's small markup to { html, text }. */
export function renderBody(input: string): { html: string; text: string };
