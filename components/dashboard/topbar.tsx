"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";

export type SearchItem = {
  label: string; sub: string | null; href: string; group: string;
};

/**
 * 4.1 — the top navigation, minus the parts of it this product does not have.
 *
 * WHAT IS HERE: universal search (⌘K) and Quick Add. Both are real: every
 * destination exists and every result is a row somebody can open.
 *
 * WHAT IS NOT, and why, because a nav bar of dead affordances is worse than a
 * short one:
 *
 *  - NOTIFICATION BELL. Nothing in the staff app writes an unread count.
 *    Notifications are email; there is no notification centre to open. The one
 *    thing genuinely waiting on a studio is in "Needs you" on this same
 *    screen, and a bell would be a second indicator for one fact that opens
 *    nothing on the days there is none. Same call the member app made.
 *  - INBOX. Messages are composed per member from /members/[id]/message and
 *    nothing writes an inbound message — there is no channel a member can
 *    reply on. An inbox would be an empty screen forever.
 *  - FLOATING AI ASSISTANT (4.15). Deliberately absent. The dashboard's whole
 *    argument is that it knew before you asked; an "ask me anything" box is
 *    the opposite of that, and 4.15 is Phase 3 in the Bible's own MVP split.
 *  - PROFILE MENU. The rail already carries the signed-in user and sign-out at
 *    its foot. Two of them is one too many.
 *  - SIDEBAR COLLAPSE. The rail is already a drawer below md, which is the
 *    case collapsing exists for.
 */
export default function TopBar({
  breadcrumb, quickAdd, search,
}: {
  /** Optional, and omitted on the dashboard: `/` is the root, so its
   *  breadcrumb is the page title, and AppShell already sets that as the h1.
   *  Two DASHBOARDs stacked is the same word twice in two type sizes. */
  breadcrumb?: string;
  quickAdd: { label: string; href: string; sub: string }[];
  search: (q: string) => Promise<SearchItem[]>;
}) {
  const [open, setOpen] = useState(false);
  const [addOpen, setAddOpen] = useState(false);
  const [q, setQ] = useState("");
  const [hits, setHits] = useState<SearchItem[]>([]);
  const [busy, setBusy] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const router = useRouter();

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setOpen((v) => !v);
      }
      if (e.key === "Escape") { setOpen(false); setAddOpen(false); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  useEffect(() => { if (open) inputRef.current?.focus(); }, [open]);

  // Debounced, and the answer is dropped if a later keystroke has already
  // asked — otherwise a slow query for "ma" lands after a fast one for
  // "maria" and the list goes backwards under the cursor.
  const seq = useRef(0);
  useEffect(() => {
    const term = q.trim();
    if (term.length < 2) { setHits([]); setBusy(false); return; }
    const mine = ++seq.current;
    setBusy(true);
    const t = setTimeout(() => {
      search(term).then((r) => {
        if (seq.current !== mine) return;
        setHits(r); setBusy(false);
      }).catch(() => { if (seq.current === mine) { setHits([]); setBusy(false); } });
    }, 180);
    return () => clearTimeout(t);
  }, [q, search]);

  return (
    <>
      <div className="topbar -mx-5 mb-6 px-5 py-2.5 md:-mx-8 md:px-8">
        <div className="flex items-center gap-3">
          {/* --ink-2, NOT --ink-3, wherever this does appear. The bar is
              translucent, so its ground is whatever scrolls under it —
              measured at 4.43 with the amber money banner behind it, under the
              floor. CLAUDE.md's rule for the member app's page wash applies
              here for the same reason: --ink-3 is 4.59 on pure white and any
              tint at all puts it below 4.5. */}
          {breadcrumb && (
            <span className="section-label shrink-0 text-ink-2">{breadcrumb}</span>
          )}

          <button
            onClick={() => setOpen(true)}
            className="flex min-w-0 flex-1 items-center gap-2 rounded-lg border border-line-2 bg-surface px-3 py-1.5 text-left text-[13px] leading-5 text-ink-3 hover:border-ink-3"
          >
            <span aria-hidden>⌕</span>
            <span className="truncate">Search members, classes, instructors…</span>
            <kbd className="num ml-auto hidden shrink-0 rounded border border-line-2 bg-paper px-1.5 py-0.5 text-[10px] leading-4 text-ink-3 sm:block">
              ⌘K
            </kbd>
          </button>

          {quickAdd.length > 0 && (
          <div className="relative shrink-0">
            <button
              onClick={() => setAddOpen((v) => !v)}
              aria-expanded={addOpen}
              className="flex h-8 items-center gap-1.5 rounded-lg bg-ink px-3 text-[13px] font-medium leading-5 text-paper hover:bg-ink-2"
            >
              <span aria-hidden>+</span>
              <span className="hidden sm:inline">Add</span>
            </button>
            {addOpen && (
              <>
                <div className="fixed inset-0 z-40" onClick={() => setAddOpen(false)} />
                <div className="panel absolute right-0 z-50 mt-1.5 w-[260px] p-1.5">
                  {quickAdd.map((a) => (
                    <Link
                      key={a.href}
                      href={a.href}
                      onClick={() => setAddOpen(false)}
                      className="block rounded px-2.5 py-2 hover:bg-paper"
                    >
                      <span className="block text-[13px] font-medium leading-[18px] text-ink">{a.label}</span>
                      <span className="block text-[11px] leading-4 text-ink-3">{a.sub}</span>
                    </Link>
                  ))}
                </div>
              </>
            )}
          </div>
          )}
        </div>
      </div>

      {open && (
        <div className="scrim flex items-start justify-center p-4 pt-[12vh]" onClick={() => setOpen(false)}>
          <div
            className="panel w-full max-w-[560px] overflow-hidden"
            onClick={(e) => e.stopPropagation()}
          >
            <input
              ref={inputRef}
              value={q}
              onChange={(e) => setQ(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && hits[0]) { setOpen(false); router.push(hits[0].href); }
              }}
              placeholder="Search members, classes, instructors, rooms, plans…"
              className="w-full border-b border-line px-4 py-3 text-[15px] leading-6 text-ink outline-none placeholder:text-ink-3"
            />
            <ul className="max-h-[52vh] overflow-y-auto p-1.5">
              {q.trim().length < 2 ? (
                <li className="px-3 py-4 text-[13px] leading-5 text-ink-3">
                  Type two letters or more. Members, classes, instructors, rooms,
                  class types and plans.
                </li>
              ) : busy ? (
                <li className="px-3 py-4 text-[13px] leading-5 text-ink-3">Looking…</li>
              ) : hits.length === 0 ? (
                <li className="px-3 py-4 text-[13px] leading-5 text-ink-3">
                  Nothing matching &ldquo;{q}&rdquo;.
                </li>
              ) : hits.map((i) => (
                <li key={i.href + i.label}>
                  <Link
                    href={i.href}
                    onClick={() => setOpen(false)}
                    className="flex items-baseline justify-between gap-3 rounded px-3 py-2 hover:bg-paper"
                  >
                    <span className="min-w-0">
                      <span className="block truncate text-[13px] leading-[18px] text-ink">{i.label}</span>
                      {i.sub && <span className="block truncate text-[11px] leading-4 text-ink-3">{i.sub}</span>}
                    </span>
                    <span className="shrink-0 text-[10px] uppercase leading-4 tracking-[0.06em] text-ink-3">
                      {i.group}
                    </span>
                  </Link>
                </li>
              ))}
            </ul>
          </div>
        </div>
      )}
    </>
  );
}
