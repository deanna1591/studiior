export const BACKOFF_MINUTES: number[];
export const MAX_ATTEMPTS: number;
export function backoffMinutes(attempts: number): number | null;
export function retryDelaySeconds(attempts: number, retryAfterSeconds: number | null): number | null;
export function throttleIntervalMs(ratePerSecond: number): number;
export function isQuota(statusCode: number | null, body: string | null): boolean;
export function isRetriable(statusCode: number | null, body: string | null, timedOut: boolean): boolean;
export function canRetry(attempts: number): boolean;
