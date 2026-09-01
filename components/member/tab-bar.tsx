"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { Icon, type IconName } from "./icons";

/**
 * Five tabs, fixed to the bottom.
 *
 * Not the staff rail shrunk: a rail costs horizontal space a phone has none of
 * and puts navigation under the hand holding the device. Check in sits in the
 * middle because it is the one you press with a bag on your shoulder.
 *
 * The active tab takes the studio's accent, not Studiior's lime — including
 * the pill behind the icon, which is the accent's tint. Both come from the
 * derived ramp, so a studio on Bold gets a light accent on a dark bar and one
 * on Warm gets the opposite, without either being written down here.
 *
 * No glass. The bar sits on the app's own surface with content scrolling to
 * its edge, not under it, so there is nothing behind it to refract — and a
 * blurred layer pinned to the viewport is repainted on every scroll frame.
 */
const TABS: { href: string; label: string; icon: IconName }[] = [
  { href: "/", label: "Home", icon: "home" },
  { href: "/book", label: "Book", icon: "calendar" },
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
    <nav className="m-tabbar fixed inset-x-0 bottom-0 z-30 border-t border-line bg-surface">
      <ul className="mx-auto flex max-w-lg">
        {TABS.map((t) => {
          const active = t.href === "/" ? pathname === "/" : pathname.startsWith(t.href);
          const badge = badges[t.href] ?? 0;
          return (
            <li key={t.href} className="flex-1">
              <Link
                href={t.href}
                aria-current={active ? "page" : undefined}
                className="flex min-h-[56px] flex-col items-center justify-center gap-0.5"
                style={{ color: active ? "var(--lime-text)" : "var(--ink-3)" }}
              >
                <span
                  className="relative flex h-7 w-11 items-center justify-center rounded-full"
                  style={active ? { background: "var(--lime-tint)" } : undefined}
                >
                  <Icon name={t.icon} size={22} active={active} />
                  {badge > 0 && (
                    <span
                      className="num absolute -right-0.5 -top-1 flex h-4 min-w-4 items-center justify-center rounded-full px-1 text-[10px] font-semibold leading-none"
                      style={{ background: "var(--coral-deep)", color: "#FFFFFF" }}
                    >
                      {badge > 9 ? "9+" : badge}
                      <span className="sr-only"> waiting for an answer</span>
                    </span>
                  )}
                </span>
                <span className={`text-[11px] leading-3 ${active ? "font-medium" : ""}`}>{t.label}</span>
              </Link>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
