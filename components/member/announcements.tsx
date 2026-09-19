"use client";

import { useState, useTransition } from "react";
import { focalPoint } from "@/lib/focal";
import { dismissAnnouncement } from "@/app/member/actions";
import { Icon } from "@/components/member/icons";

export type Announcement = {
  id: string; kind: string; title: string; body: string;
  image_url: string | null; image_focus_x: number; image_focus_y: number;
  link_url: string | null; link_label: string | null;
  pinned: boolean;
};

/**
 * Decision 27 — "What's on", from the studio. One-way: read it, dismiss it, done.
 * No replies, no reactions (not a feed). Dismiss is optimistic — the card leaves
 * the moment it is tapped; a pinned one has no dismiss and stays until it ends.
 *
 * Amendment: only POSTS render here — banners are the strip at the top of the
 * screen (AnnounceStrip). An optional link is a button under the body; a
 * same-host link opens in place, an external one in a new tab.
 */
export default function Announcements({ items }: { items: Announcement[] }) {
  const [hidden, setHidden] = useState<Record<string, boolean>>({});
  const [, startTransition] = useTransition();
  const shown = items.filter((a) => a.kind !== "banner" && !hidden[a.id]);
  if (shown.length === 0) return null;

  function dismiss(id: string) {
    setHidden((h) => ({ ...h, [id]: true }));
    startTransition(() => { dismissAnnouncement(id); });
  }

  // A link into the member app opens in place; an external one in a new tab.
  function open(url: string) {
    try {
      const u = new URL(url, window.location.href);
      if (u.host === window.location.host) window.location.assign(u.href);
      else window.open(u.href, "_blank", "noopener,noreferrer");
    } catch {
      window.open(url, "_blank", "noopener,noreferrer");
    }
  }

  return (
    <section className="mt-5 space-y-3">
      <h2 className="m-eyebrow font-semibold text-ink">What&rsquo;s on</h2>
      {shown.map((a) => (
        <article key={a.id} className="m-card overflow-hidden">
          {a.image_url && (
            <span className="block h-32 w-full overflow-hidden">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={a.image_url} alt="" aria-hidden className="h-full w-full object-cover"
                   style={{ objectPosition: focalPoint(a.image_focus_x, a.image_focus_y) }} />
            </span>
          )}
          <div className="flex items-start gap-2 p-4">
            <div className="min-w-0 flex-1">
              <p className="m-name text-ink">{a.title}</p>
              <p className="m-sub mt-1 whitespace-pre-line text-ink-2">{a.body}</p>
              {a.link_url && (
                <button type="button" onClick={() => open(a.link_url!)}
                   /* --ink on --accent-chip (11.42 worst), never --lime-text on
                      the accent tint — that pairing measures 3.88 and fails on
                      Bold (CLAUDE.md: accent text on accent tint is not a pair). */
                   className="m-press mt-2.5 inline-flex items-center gap-1.5 rounded-full px-3.5 py-1.5 text-[13px] font-semibold"
                   style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>
                  {a.link_label || "Learn more"}
                  <Icon name="arrow-out" size={14} />
                </button>
              )}
            </div>
            {!a.pinned && (
              <button type="button" onClick={() => dismiss(a.id)} aria-label="Dismiss"
                      className="m-press -mr-1 -mt-1 shrink-0 rounded-full p-1.5 text-ink-3">
                <Icon name="x" size={16} />
              </button>
            )}
          </div>
        </article>
      ))}
    </section>
  );
}
