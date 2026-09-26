// Types for lib/auth-redirect.mjs (the runtime is ESM JS so `node --test` can
// import it without a TypeScript loader; see the .mjs header).
export function safeNext(next: string | null | undefined): string;
export function buildAuthCallback(memberOrigin: string, next: string | null | undefined): string;
