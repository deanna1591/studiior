"use client";

import { useState, useTransition } from "react";
import { focalPoint } from "@/lib/focal";
import { dismissAnnouncement } from "@/app/member/actions";
import { Icon } from "@/components/member/icons";

export type Announcement = {
  id: string; title: string; body: string;
  image_url: string | null; image_focus_x: number; image_focus_y: number;
  pinned: boolean;
};

/**
 * Decision 27 — what's on, from the studio. One-way: read it, dismiss it, done.
 * No replies, no reactions (not a feed). Dismiss is optimistic — the card leaves
 * the moment it is tapped; a pinned one has no dismiss and stays until it ends.
 */
export default function Announcements({ items }: { items: Announcement[] }) {
  const [hidden, setHidden] = useState<Record<string, boolean>>({});
  const [, startTransition] = useTransition();
  const shown = items.filter((a) => !hidden[a.id]);
  if (shown.length === 0) return null;

  function dismiss(id: string) {
    setHidden((h) => ({ ...h, [id]: true }));
    startTransition(() => { dismissAnnouncement(id); });
  }

  return (
    <section className="mb-5 space-y-3">
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
