"use client";

import { useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";

export type RailItem = { href: string; label: string };
export type RailGroup = { heading: string | null; items: RailItem[] };
export type RailUser = { email: string; role: string };

/**
 * The persistent left rail: who you are looking at, at the top; where you can
 * go, in the middle; who you are, at the bottom.
 *
 * The middle is GROUPED (Timetable, People, Team, Selling, Studio) rather than
 * one flat list of eighteen — a nav you use, not a list you scan. Groups are
 * collapsible, and the group holding the page you are on is open while the rest
 * are closed: below lg the rail is a drawer, and a grouped drawer fully
 * expanded is more scrolling than the flat list it replaced. `lib/nav.ts`
 * decides which items and groups a role sees; this only draws them.
 *
 * Below lg it becomes a drawer rather than a bottom bar. Front desk runs this
 * on an iPad at a counter, where the check-in roster wants every vertical
 * pixel it can get, and a bottom bar would also split studio identity from the
 * signed-in user across two edges of the screen.
 */
export default function Rail({
  studioName, location, groups, user, signOut,
}: {
  studioName: string;
  location: string | null;
  groups: RailGroup[];
  user: RailUser;
  signOut?: React.ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const pathname = usePathname();

  // The single active item is the LONGEST href that prefixes the path, so
  // `/settings/closures` lights Closures and not Settings, and `/shifts/cover`
  // Cover and not Open shifts. `/` only matches itself.
  let activeHref = "";
  for (const g of groups) {
    for (const it of g.items) {
      const hit = it.href === "/" ? pathname === "/" : pathname === it.href || pathname.startsWith(it.href + "/");
      if (hit && it.href.length > activeHref.length) activeHref = it.href;
    }
  }
  const activeHeading = groups.find((g) => g.items.some((it) => it.href === activeHref))?.heading ?? null;

  // A group defaults open when it holds the active page; the reader may still
  // toggle any group, and the active group's default follows the path so the
  // section you navigate into opens itself.
  const [toggled, setToggled] = useState<Record<string, boolean>>({});
  const isOpen = (heading: string) => toggled[heading] ?? heading === activeHeading;

  const Item = ({ it }: { it: RailItem }) => {
    const active = it.href === activeHref;
    return (
      <Link
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
  };

  const body = (
    <div className="flex h-full flex-col bg-surface">
      <div className="border-b border-line px-4 py-4">
        <div className="display-sm text-ink">{studioName}</div>
        {location && <div className="mt-1 text-[11px] leading-[14px] text-ink-3">{location}</div>}
      </div>

      <nav className="flex-1 overflow-y-auto py-2">
        {groups.map((g, gi) =>
          g.heading === null ? (
            <div key={`top-${gi}`} className="mb-1">
              {g.items.map((it) => <Item key={it.href} it={it} />)}
            </div>
          ) : (
            <div key={g.heading} className="mt-1">
              <button
                type="button"
                onClick={() => setToggled((t) => ({ ...t, [g.heading!]: !isOpen(g.heading!) }))}
                aria-expanded={isOpen(g.heading)}
                className="flex w-full items-center justify-between px-4 py-1.5 text-[11px] font-semibold uppercase tracking-[0.06em] text-ink-3 hover:text-ink-2"
              >
                {g.heading}
                <svg
                  width="10" height="10" viewBox="0 0 10 10" aria-hidden
                  className={`transition-transform ${isOpen(g.heading) ? "" : "-rotate-90"}`}
                >
                  <path d="M1.5 3.5 5 7l3.5-3.5" stroke="currentColor" strokeWidth="1.4"
                        fill="none" strokeLinecap="round" strokeLinejoin="round" />
                </svg>
              </button>
              {isOpen(g.heading) && (
                <div className="pb-1">
                  {g.items.map((it) => <Item key={it.href} it={it} />)}
                </div>
              )}
            </div>
          )
        )}
      </nav>

      <div className="border-t border-line px-4 py-3">
        <div className="truncate text-[13px] leading-[18px] text-ink">{user.email}</div>
        <div className="mt-0.5 text-[11px] leading-[14px] capitalize text-ink-3">
          {user.role.replace("_", " ")}
        </div>
        {signOut && <div className="mt-2">{signOut}</div>}
      </div>
    </div>
  );

  return (
    <>
      {/* Compact header, below lg only. */}
      <div className="sticky top-0 z-30 flex h-14 items-center gap-3 border-b border-line bg-surface px-4 lg:hidden">
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
        <div className="fixed inset-0 z-40 lg:hidden">
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

      <aside className="fixed inset-y-0 left-0 z-20 hidden w-[--rail-w] border-r border-line lg:block">
        {body}
      </aside>
    </>
  );
}
