// Decision 58 FIX B — an instructor may ask for cover only BEFORE the class
// starts. At or after the start instant the ask is closed (the roster hides the
// form; request_cover refuses it with PT422 even on a stale page). Pure, so the
// page, the action and a node test agree.
export function coverRequestAllowed(nowMs, classStartMs) {
  return typeof nowMs === "number" && typeof classStartMs === "number" && nowMs < classStartMs;
}
