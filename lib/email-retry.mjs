/**
 * Decision 113: the send worker's throttle and retry schedule, as pure helpers
 * that mirror the SQL in reconcile_notification_sends() / send_due_notifications().
 * A 429 (not a quota stop) or a network failure re-schedules with backoff at
 * 1, 5, 15, 60 and 240 minutes (five retries), honouring a retry-after header,
 * then fails. A 422 (bad address) and a quota 429 are terminal.
 */
export const BACKOFF_MINUTES = [1, 5, 15, 60, 240];
export const MAX_ATTEMPTS = 6; // the initial send plus five retries

/** Minutes to wait before the next attempt, given how many have already failed
 *  (1-indexed). null once the five backoff slots are used up. */
export function backoffMinutes(attempts) {
  if (!Number.isInteger(attempts) || attempts < 1 || attempts > BACKOFF_MINUTES.length) return null;
  return BACKOFF_MINUTES[attempts - 1];
}

/** Seconds to wait: a retry-after header wins (capped at an hour), else the
 *  backoff. null when there are no retries left. */
export function retryDelaySeconds(attempts, retryAfterSeconds) {
  if (retryAfterSeconds != null && retryAfterSeconds > 0) return Math.min(retryAfterSeconds, 3600);
  const m = backoffMinutes(attempts);
  return m == null ? null : m * 60;
}

/** Milliseconds between posts to hold the rate at or under ratePerSecond. */
export function throttleIntervalMs(ratePerSecond) {
  return 1000 / Math.max(ratePerSecond || 0, 1);
}

/** A quota stop (daily/monthly) is a 429 but is never retried. */
export function isQuota(statusCode, body) {
  const b = String(body || "").toLowerCase();
  return statusCode === 429 &&
    (b.includes("quota_exceeded") || b.includes("daily_quota") || b.includes("monthly_quota"));
}

/** Retriable: a rate-limit 429, or a network failure (timed out / no status). */
export function isRetriable(statusCode, body, timedOut) {
  if (statusCode === 422) return false;
  if (isQuota(statusCode, body)) return false;
  if (statusCode === 429) return true;
  if (timedOut) return true;
  if (statusCode == null) return true;
  return false;
}

export function canRetry(attempts) {
  return attempts < MAX_ATTEMPTS;
}
