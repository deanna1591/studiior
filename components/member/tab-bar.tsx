"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { Icon, type IconName } from "./icons";

/**
 * Five tabs, as a pill floating clear of the screen edges.
 *
 * Floating rather than flush, and this is the one place blur earns itself in
 * the member app: the washed page scrolls UNDER the bar, so there is a moving
 * gradient and moving cards behind it to refract. A flush bar sits on the app's
 * own surface with nothing behind it, which is the case the "no glass" rule was
 * written for — and it also cuts the page off with a hard line, which is what
 * made the app read as a document with a footer.
 *
 * The list gets bottom padding to clear it, so nothing is ever parked under the
 * bar with no way to scroll it out.
 *
 * The active tab takes the studio's accent, never Studiior's lime, from the
 * derived ramp — a studio on Bold gets a light accent on the bar and one on
 * Warm the opposite, without either being written down here.
 */
const TABS: { href: string; label: string; icon: IconName }[] = [
  // Book first, per the mockup. A member opens this app to book far more often
  // than to look at anything else, and the leftmost tab is the one the thumb
  // finds without aiming.
  { href: "/book", label: "Book", icon: "calendar" },
  { href: "/", label: "Home", icon: "home" },
  { href: "/check-in", label: "Check in", icon: "qr" },
  { href: "/history", label: "History", icon: "clock" },
  // "Account", not "Plan": this tab holds the membership, the credits, the
  // payment state AND the member's own profile, and a card icon promised only
  // the first of those.
  { href: "/account", label: "Account", icon: "user" },
];

export default function TabBar({ badges = {} }: { badges?: Partial<Record<string, number>> }) {
  const pathname = usePathname();
  return (
    <nav className="m-tabbar-float z-30 mx-auto max-w-lg">
      <ul className="flex items-stretch px-1.5 py-1.5">
        {TABS.map((t) => {
          const active = t.href === "/" ? pathname === "/" : pathname.startsWith(t.href);
          const badge = badges[t.href] ?? 0;
          return (
            <li key={t.href} className="flex-1">
              <Link
                href={t.href}
                aria-current={active ? "page" : undefined}
                className="flex min-h-[50px] flex-col items-center justify-center gap-1 rounded-[20px]"
                style={
                  active
                    ? { background: "var(--accent-solid)", color: "var(--accent-on-solid)" }
                    : { color: "var(--ink-2)" }
                }
              >
                <span className="relative flex items-center justify-center">
                  <Icon name={t.icon} size={20} active={active} />
                  {badge > 0 && (
                    <span
                      className="num absolute -right-2 -top-1.5 flex h-4 min-w-4 items-center justify-center rounded-full px-1 text-[10px] font-semibold leading-none"
                      style={{ background: "var(--coral-deep)", color: "#FFFFFF" }}
                    >
                      {badge > 9 ? "9+" : badge}
                      <span className="sr-only"> waiting for an answer</span>
                    </span>
                  )}
                </span>
                <span className="text-[10px] font-medium leading-none">{t.label}</span>
              </Link>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
