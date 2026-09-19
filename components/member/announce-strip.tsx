"use client";

import { useState, useTransition } from "react";
import { dismissAnnouncement } from "@/app/member/actions";
import { Icon } from "@/components/member/icons";

export type StripItem = {
  id: string;
  title: string;
  linkUrl: string | null;
  linkLabel: string | null;
};

/**
 * Decision 27 (amendment) — a BANNER announcement, the one filled bar on the
 * screen. Title only. It takes the accent's primary-button pair
 * (accentRamp().solid / onSolid, exposed as --accent-solid / --accent-on-solid),
 * so it separates from the tinted cards on every preset and accent — no raw hex,
 * which would be wrong on a green-accent studio and on Bold. The X and the arrow
 * take onSolid too.
 *
 * A banner with a link is tappable: a same-host link (into the member app) opens
 * in place, an external one in a new tab, and a small arrow signals it. A banner
 * with no link is a static line with a dismiss X. Dismissal is the shared
 * dismiss_announcement, so an X here clears it on Home and Book together.
 *
 * `dismissible` is false in the instructor portal — a roster-relevant notice is
 * not something to swipe away, and an instructor has no member row to dismiss
 * against anyway.
 */
export default function AnnounceStrip({
  items, dismissible = true,
}: { items: StripItem[]; dismissible?: boolean }) {
  const [hidden, setHidden] = useState<Record<string, boolean>>({});
  const [, startTransition] = useTransition();
  const shown = items.filter((a) => !hidden[a.id]);
  if (shown.length === 0) return null;

  function dismiss(id: string) {
    setHidden((h) => ({ ...h, [id]: true }));
    startTransition(() => { dismissAnnouncement(id); });
  }

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
    <div className="mb-4 space-y-2">
      {shown.map((a) => (
        <div key={a.id}
             className="flex items-center gap-2 rounded-2xl px-3.5 py-2.5"
             style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
          {a.linkUrl ? (
            <button type="button" onClick={() => open(a.linkUrl!)}
                    className="m-press flex min-w-0 flex-1 items-center gap-1.5 text-left"
                    aria-label={`${a.title} — ${a.linkLabel ?? "Learn more"}`}>
              <span className="truncate text-[14px] font-semibold leading-5">{a.title}</span>
              <Icon name="arrow-out" size={15} className="shrink-0 opacity-90" />
            </button>
          ) : (
            <span className="min-w-0 flex-1 truncate text-[14px] font-semibold leading-5">{a.title}</span>
          )}
          {dismissible && (
            <button type="button" onClick={() => dismiss(a.id)} aria-label="Dismiss"
                    className="m-press shrink-0 rounded-full p-1 opacity-90">
              <Icon name="x" size={16} />
            </button>
          )}
        </div>
      ))}
    </div>
  );
}
