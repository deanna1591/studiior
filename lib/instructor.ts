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
};

/**
 * Resolves auth.uid() -> studio_staff -> instructors, and sends anybody who is
 * not an instructor to the login screen rather than showing them an empty
 * portal. Never takes an id: the one thing this must not do is answer for
 * somebody else.
 */
export async function instructorScreen() {
  const supabase = createClient();
  const { data } = await supabase.rpc("my_instructor");
  const ctx = data as InstructorContext | null;
  if (!ctx?.instructor_id) redirect("/instructor/login");
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
