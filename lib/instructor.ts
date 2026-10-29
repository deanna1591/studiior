import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

/**
 * The instructor portal's context, in ONE request.
 *
 * WHERE THIS LIVES, AND WHY: `{slug}.studiior.app/instructor`, i.e. the member
 * domain's subtree, rewritten by middleware to app/member/instructor.
 *
 *  - An instructor on a phone between classes needs a phone app, and the member
 *    PWA is the only phone-shaped surface this product has. Its tokens, its
 *    shell, its tab bar, its `themeVars()` and its installability all come free.
 *  - The subdomain already identifies the studio, which is exactly the scope an
 *    instructor works in.
 *  - The staff app is a rail and tables, deliberately unthemed, and built on the
 *    assumption of a desk and a mouse. Putting a phone app inside it would mean
 *    either a third design language or fighting the shell on every screen.
 *
 * The cost, stated: an instructor who is also a MEMBER of the same studio uses
 * one host for both, and the two are told apart by the path. That is the right
 * trade — they are the same person on the same phone at the same studio, and
 * making them remember two addresses would be worse.
 */
export type InstructorContext = {
  instructor_id: string;
  display_name: string;
  avatar_url: string | null;
  bio: string | null;
  studio_id: string;
  studio_name: string;
  slug: string;
  timezone: string;
  currency: string;
  accent_color: string | null;
  theme_preset: string | null;
  logo_url: string | null;
  email: string;
  role: string;
  usesPayroll: boolean;
  /** Decision 54: the studio's week start (0=Sun..6=Sat) so My schedule pages by
   *  week, and its clock format so the portal formats the few times it builds
   *  client-side (the Open-classes end time). Both from my_instructor. */
  week_starts_on: number;
  time_format: "24h" | "12h";
  /** Unread in-app notifications, for the bell. Resolved once per screen. */
  unread: number;
  /** Decision 85 — the per-person guide flags: whether the five-card intro has
   *  been seen, and which one-line hints have been dismissed. Both from
   *  my_instructor; the DB holds nothing studio-specific. */
  guide_seen_at: string | null;
  hints_seen: Record<string, boolean>;
  /** The studio's guarantee/flex switches, so the instructor-facing core/flex tag
   *  shows only the tier the studio actually runs (both off = no tag). Read in the
   *  SAME wave as my_instructor, so no extra serial hop (Decision 82). */
  guaranteesEnabled: boolean;
  flexEnabled: boolean;
};

/**
 * Resolves auth.uid() -> studio_staff -> instructors, and sends anybody who is
 * not an instructor to the login screen rather than showing them an empty
 * portal. Never takes an id: the one thing this must not do is answer for
 * somebody else.
 */
export async function instructorScreen() {
  const supabase = createClient();
  // Decision 82: my_instructor now carries uses_payroll + unread, so the portal
  // context is ONE round trip. It used to be my_instructor, then a second wave
  // for [studio_uses_payroll, instructor_notifications] — paid on every
  // instructor screen before the page did any work of its own.
  // my_instructor is one round trip; the studio's guarantee/flex switches ride
  // the SAME wave (parallel, not a serial hop) so the core/flex tag can show only
  // the tier the studio runs. settings_staff_read scopes the row to the
  // instructor's own studio(s); we pick the one this portal is for.
  const [{ data }, { data: settingsRows }] = await Promise.all([
    supabase.rpc("my_instructor"),
    supabase.from("studio_settings").select("studio_id, guarantees_enabled, flex_enabled"),
  ]);
  const ctx = data as (InstructorContext & { uses_payroll?: boolean }) | null;
  if (!ctx?.instructor_id) redirect("/instructor/login");
  const gs = (settingsRows ?? []).find((r) => r.studio_id === ctx.studio_id);
  ctx.guaranteesEnabled = gs?.guarantees_enabled ?? false;
  ctx.flexEnabled = gs?.flex_enabled ?? false;
  // Payroll is opt-in (migration 139): the Pay tab shows only when the studio
  // uses the guarantee system — a studio that pays in its own books shows no Pay
  // tab (absent, not empty). The unread count drives the bell on every screen.
  ctx.usesPayroll = ctx.uses_payroll === true;
  ctx.unread = Number((data as { unread?: number } | null)?.unread ?? 0);
  // Decision 85: normalise the guide flags (my_instructor returns them snake-cased).
  ctx.guide_seen_at = (ctx.guide_seen_at ?? null) as string | null;
  ctx.hints_seen = (ctx.hints_seen ?? {}) as Record<string, boolean>;
  return { ctx, supabase };
}

/** The studio's own date, computed rather than fetched — Intl carries the same
 *  IANA rules Postgres does, and a page holding a timezone should not pay a
 *  round trip to learn what day it is. */
export function studioToday(timeZone: string, offsetDays = 0): string {
  const d = new Date();
  if (offsetDays) d.setUTCDate(d.getUTCDate() + offsetDays);
  return new Intl.DateTimeFormat("en-CA", { timeZone }).format(d);
}

export function shiftDate(key: string, days: number): string {
  const [y, m, d] = key.split("-").map(Number);
  const t = new Date(Date.UTC(y, m - 1, d));
  t.setUTCDate(t.getUTCDate() + days);
  return t.toISOString().slice(0, 10);
}
