// Types for lib/password-reset.mjs (the runtime is ESM JS so `node --test` can
// import it without a TypeScript loader; see the .mjs header).
export const RESET_SENT: string;
export const MIN_PASSWORD: number;
export function requestOutcome(email: string | null | undefined): { ok: true } | { error: string };
export function validateNewPassword(
  password: string | null | undefined,
  confirm: string | null | undefined,
): { ok: true } | { error: string };
export function resetNext(role: string | null | undefined): string;
export function resetRedirect(role: string | null | undefined): string;
