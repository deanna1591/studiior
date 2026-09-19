"use client";

import { useState, useTransition } from "react";
import { dismissAnnouncement } from "@/app/member/actions";
import { Icon } from "@/components/member/icons";

export type StripItem = { id: string; title: string; body: string };

/**
 * Decision 27 on /book — the studio's own pinned message where members choose a
 * class. Compact: one line (title), tap to expand the body, X to dismiss. It
 * uses the same dismiss_announcement as Home, so a dismissal here is a dismissal
 * there. ONLY pinned announcements reach this strip (the caller filters);
 * unpinned ones stay Home-only.
 */
export default function AnnounceStrip({ items }: { items: StripItem[] }) {
  const [hidden, setHidden] = useState<Record<string, boolean>>({});
  const [open, setOpen] = useState<Record<string, boolean>>({});
  const [, startTransition] = useTransition();
  const shown = items.filter((a) => !hidden[a.id]);
  if (shown.length === 0) return null;

  function dismiss(id: string) {
    setHidden((h) => ({ ...h, [id]: true }));
    startTransition(() => { dismissAnnouncement(id); });
  }

  return (
    <div className="mb-4 space-y-2">
      {shown.map((a) => (
        <div key={a.id} className="m-card px-3.5 py-2.5" style={{ background: "var(--accent-chip)" }}>
          <div className="flex items-center gap-2">
            <button type="button" onClick={() => setOpen((o) => ({ ...o, [a.id]: !o[a.id] }))}
                    aria-expanded={!!open[a.id]}
                    className="m-press flex min-w-0 flex-1 items-center gap-2 text-left">
              <span className="truncate text-[14px] font-semibold leading-5 text-ink">{a.title}</span>
              <span className={`shrink-0 text-ink-3 transition-transform ${open[a.id] ? "rotate-180" : ""}`}>
                <Icon name="chevron-down" size={16} />
              </span>
            </button>
            <button type="button" onClick={() => dismiss(a.id)} aria-label="Dismiss"
                    className="m-press shrink-0 rounded-full p-1 text-ink-3">
              <Icon name="x" size={16} />
            </button>
          </div>
          {open[a.id] && (
            <p className="m-sub mt-2 whitespace-pre-line text-ink-2">{a.body}</p>
          )}
        </div>
      ))}
    </div>
  );
}
