/**
 * A short buzz to confirm a physical-feeling action — booking, cancelling,
 * checking in.
 *
 * HONEST ABOUT THE PLATFORM SPLIT. The Vibration API works on Android Chrome
 * and is a no-op — not an error — everywhere it does not: iOS Safari has never
 * implemented `navigator.vibrate`, and the one trick that fakes it (a hidden
 * `<input type="checkbox" switch>`) is unreliable and needs a real prior user
 * gesture, so it is not worth the maintenance. The rule this file follows is
 * the same as the rest of the app: feel where the platform offers it, silence
 * where it does not, never a broken control.
 *
 * So: haptics are real on Android and a clean no-op on iOS. The optimistic
 * card flip and the press state are what carry the confirmation on iOS, and
 * they were going to carry most of it on Android too.
 */
type Haptic = "tap" | "success" | "warning";

const PATTERNS: Record<Haptic, number | number[]> = {
  // A single short pulse for a confirmed action.
  tap: 8,
  // Two quick pulses — booked, checked in.
  success: [10, 40, 12],
  // A longer single pulse — something was refused or undone.
  warning: 24,
};

export function haptic(kind: Haptic = "tap"): void {
  // Guarded: `navigator` is undefined during SSR, and `vibrate` is absent on
  // iOS. Both fall through to nothing.
  if (typeof navigator === "undefined") return;
  const nav = navigator as Navigator & { vibrate?: (p: number | number[]) => boolean };
  if (typeof nav.vibrate !== "function") return;
  try {
    nav.vibrate(PATTERNS[kind]);
  } catch {
    // Some browsers throw if called outside a user gesture. A buzz is never
    // worth an exception.
  }
}
