import { test } from "node:test";
import assert from "node:assert/strict";
import {
  backoffMinutes, retryDelaySeconds, throttleIntervalMs, isQuota, isRetriable,
  canRetry, BACKOFF_MINUTES, MAX_ATTEMPTS,
} from "../lib/email-retry.mjs";

test("backoff schedule is 1,5,15,60,240 minutes then null", () => {
  assert.deepEqual(BACKOFF_MINUTES, [1, 5, 15, 60, 240]);
  assert.deepEqual([1, 2, 3, 4, 5].map(backoffMinutes), [1, 5, 15, 60, 240]);
  assert.equal(backoffMinutes(6), null);
  assert.equal(backoffMinutes(0), null);
  assert.equal(MAX_ATTEMPTS, 6);
});

test("retry delay: retry-after wins (capped at an hour), else backoff, else null", () => {
  assert.equal(retryDelaySeconds(1, null), 60);
  assert.equal(retryDelaySeconds(2, null), 300);
  assert.equal(retryDelaySeconds(5, null), 240 * 60);
  assert.equal(retryDelaySeconds(6, null), null);          // retries exhausted
  assert.equal(retryDelaySeconds(1, 30), 30);              // retry-after honoured
  assert.equal(retryDelaySeconds(1, 99999), 3600);         // capped
  assert.equal(retryDelaySeconds(3, 0), 15 * 60);          // 0 retry-after ignored
});

test("throttle interval: 20/s -> 50ms, never below a 1/s floor", () => {
  assert.equal(throttleIntervalMs(20), 50);
  assert.equal(throttleIntervalMs(1), 1000);
  assert.equal(throttleIntervalMs(0), 1000);
});

test("quota 429 is distinguished from a rate-limit 429", () => {
  assert.equal(isQuota(429, "daily_quota_exceeded"), true);
  assert.equal(isQuota(429, "monthly_quota_exceeded"), true);
  assert.equal(isQuota(429, "Too many requests. 30 per second."), false);
  assert.equal(isQuota(422, "quota_exceeded"), false);     // only 429
});

test("retriable: rate-limit 429 and network; not 422, quota, or other 4xx/5xx", () => {
  assert.equal(isRetriable(429, "rate limit", false), true);
  assert.equal(isRetriable(429, "daily_quota_exceeded", false), false);
  assert.equal(isRetriable(422, "invalid to", false), false);
  assert.equal(isRetriable(null, null, true), true);        // timed out
  assert.equal(isRetriable(null, "boom", false), true);     // no status = network
  assert.equal(isRetriable(500, "server error", false), false);
  assert.equal(isRetriable(200, "", false), false);
});

test("canRetry stops at the max", () => {
  assert.equal(canRetry(1), true);
  assert.equal(canRetry(5), true);
  assert.equal(canRetry(6), false);
});
