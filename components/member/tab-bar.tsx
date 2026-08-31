"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

/**
 * Five tabs, fixed to the bottom.
 *
 * Not the staff rail shrunk: a rail costs horizontal space a phone has none of
 * and puts navigation under the hand holding the device. Check in sits in the
 * middle because it is the one you press with a bag on your shoulder.
 */
const TABS = [
  { href: "/", label: "Home", icon: "home" },
  { href: "/book", label: "Book", icon: "book" },
  { href: "/check-in", label: "Check in", icon: "qr" },
  { href: "/history", label: "History", icon: "history" },
  { href: "/membership", label: "Plan", icon: "plan" },
] as const;

function Icon({ name, active }: { name: string; active: boolean }) {
  const s = { fill: "none", stroke: "currentColor", strokeWidth: active ? 1.9 : 1.6,
              strokeLinecap: "round" as const, strokeLinejoin: "round" as const };
  return (
    <svg width="22" height="22" viewBox="0 0 22 22" aria-hidden>
      {name === "home"    && <path d="M3 9.5 11 3.5l8 6V18a1 1 0 0 1-1 1h-4v-5h-6v5H4a1 1 0 0 1-1-1z" {...s} />}
      {name === "book"    && <><rect x="3" y="4.5" width="16" height="14" rx="2" {...s} /><path d="M3 9h16M7.5 3v3M14.5 3v3" {...s} /></>}
      {name === "qr"      && <><rect x="3" y="3" width="6.5" height="6.5" rx="1.2" {...s} /><rect x="12.5" y="3" width="6.5" height="6.5" rx="1.2" {...s} /><rect x="3" y="12.5" width="6.5" height="6.5" rx="1.2" {...s} /><path d="M12.5 12.5h3v3h-3zM19 19v-3M16 19h3" {...s} /></>}
      {name === "history" && <><circle cx="11" cy="11" r="8" {...s} /><path d="M11 6v5.5l3.5 2" {...s} /></>}
      {name === "plan"    && <><rect x="2.5" y="5" width="17" height="12" rx="2" {...s} /><path d="M2.5 9.5h17" {...s} /></>}
    </svg>
  );
}

export default function TabBar() {
  const pathname = usePathname();
  return (
    <nav className="m-tabbar fixed inset-x-0 bottom-0 z-30 border-t border-line bg-surface">
      <ul className="mx-auto flex max-w-lg">
        {TABS.map((t) => {
          const active = t.href === "/" ? pathname === "/" : pathname.startsWith(t.href);
          return (
            <li key={t.href} className="flex-1">
              <Link
                href={t.href}
                aria-current={active ? "page" : undefined}
                className={`flex min-h-[56px] flex-col items-center justify-center gap-0.5 ${
                  active ? "text-lime-text" : "text-ink-3"
                }`}
              >
                <span className={`flex h-7 w-10 items-center justify-center rounded-full ${
                  active ? "bg-lime-tint" : ""}`}>
                  <Icon name={t.icon} active={active} />
                </span>
                <span className="text-[11px] leading-3">{t.label}</span>
              </Link>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
