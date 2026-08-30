"use client";

import { useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";

export type RailItem = { href: string; label: string };
export type RailUser = { email: string; role: string };

/**
 * The persistent left rail: who you are looking at, at the top; where you can
 * go, in the middle; who you are, at the bottom.
 *
 * Below md it becomes a drawer rather than a bottom bar. Front desk runs this
 * on an iPad at a counter, where the check-in roster wants every vertical
 * pixel it can get, and a bottom bar would also split studio identity from the
 * signed-in user across two edges of the screen.
 */
export default function Rail({
  studioName, location, items, user, signOut,
}: {
  studioName: string;
  location: string | null;
  items: RailItem[];
  user: RailUser;
  signOut: React.ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const pathname = usePathname();

  const body = (
    <div className="flex h-full flex-col bg-surface">
      <div className="border-b border-line px-4 py-4">
        <div className="display-sm text-ink">{studioName}</div>
        {location && <div className="mt-1 text-[11px] leading-[14px] text-ink-3">{location}</div>}
      </div>

      <nav className="flex-1 overflow-y-auto py-2">
        {items.map((it) => {
          // "/" would otherwise prefix-match every route in the app.
          const active = it.href === "/" ? pathname === "/" : pathname.startsWith(it.href);
          return (
            <Link
              key={it.href}
              href={it.href}
              onClick={() => setOpen(false)}
              className={`relative block px-4 py-2 text-[13px] leading-[18px] ${
                active
                  ? "bg-lime-tint font-medium text-lime-text"
                  : "text-ink-2 hover:bg-paper hover:text-ink"
              }`}
            >
              {active && <span className="absolute inset-y-0 left-0 w-[2px] bg-lime-text" aria-hidden />}
              {it.label}
            </Link>
          );
        })}
      </nav>

      <div className="border-t border-line px-4 py-3">
        <div className="truncate text-[13px] leading-[18px] text-ink">{user.email}</div>
        <div className="mt-0.5 text-[11px] leading-[14px] capitalize text-ink-3">
          {user.role.replace("_", " ")}
        </div>
        <div className="mt-2">{signOut}</div>
      </div>
    </div>
  );

  return (
    <>
      {/* Compact header, below md only. */}
      <div className="sticky top-0 z-30 flex h-14 items-center gap-3 border-b border-line bg-surface px-4 md:hidden">
        <button
          onClick={() => setOpen(true)}
          aria-label="Open menu"
          className="-ml-1 flex h-9 w-9 items-center justify-center rounded text-ink-2 hover:bg-paper"
        >
          <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden>
            <path d="M2 4.5h14M2 9h14M2 13.5h14" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
          </svg>
        </button>
        <span className="display-sm truncate text-ink">{studioName}</span>
      </div>

      {open && (
        <div className="fixed inset-0 z-40 md:hidden">
          {/* An inline rgba, not bg-ink/30: --ink is a plain hex in a custom
              property, and Tailwind's opacity modifier cannot slice one, so
              the utility silently produced no scrim at all. */}
          <div
            className="absolute inset-0"
            style={{ background: "rgba(20, 23, 14, 0.32)" }}
            onClick={() => setOpen(false)}
            aria-hidden
          />
          <div className="absolute inset-y-0 left-0 w-[--rail-w] border-r border-line shadow-xl">{body}</div>
        </div>
      )}

      <aside className="fixed inset-y-0 left-0 z-20 hidden w-[--rail-w] border-r border-line md:block">
        {body}
      </aside>
    </>
  );
}
