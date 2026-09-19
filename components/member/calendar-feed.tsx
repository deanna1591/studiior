"use client";

import { useState, useTransition } from "react";

/**
 * Decision 33 Part B — the subscribe-to-your-calendar control, shared by the
 * member email-settings screen and the instructor Me screen.
 *
 * The token is a credential: the mint action returns it ONCE, this reveals the
 * webcal:// URL to copy, and it is never shown again — losing it means minting a
 * fresh one (which kills the old). "Turn off" revokes; the URL goes dead.
 *
 * The URL is built from window.location.host, so it is the studio's own
 * subdomain wherever this renders — no slug has to be passed in.
 */
export type FeedActions = {
  mint: () => Promise<{ token?: string; error?: string }>;
  revoke: () => Promise<{ ok?: boolean; error?: string }>;
};

export function CalendarFeedControl({
  active, lastUsed, actions, what,
}: {
  active: boolean;
  lastUsed: string | null;
  actions: FeedActions;
  what: string; // "your classes" | "your bookings"
}) {
  const [isActive, setIsActive] = useState(active);
  const [url, setUrl] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  function feedUrl(token: string) {
    // webcal:// is the scheme every calendar app subscribes to; it maps to the
    // same https route. host is {slug}.studiior.app here.
    return `webcal://${window.location.host}/feed/${token}`;
  }

  function mint() {
    setError(null);
    start(async () => {
      const r = await actions.mint();
      if (r.error) { setError(r.error); return; }
      if (r.token) { setUrl(feedUrl(r.token)); setIsActive(true); setCopied(false); }
    });
  }

  function revoke() {
    setError(null);
    start(async () => {
      const r = await actions.revoke();
      if (r.error) { setError(r.error); return; }
      setIsActive(false); setUrl(null);
    });
  }

  async function copy() {
    if (!url) return;
    try { await navigator.clipboard.writeText(url); setCopied(true); } catch { /* clipboard blocked */ }
  }

  return (
    <div className="m-card px-4 py-4">
      <p className="text-[15px] leading-5 text-ink">Subscribe your calendar</p>
      <p className="m-sub mt-1 text-ink-2">
        Add {what} to your phone&rsquo;s calendar, and it stays up to date on its own —
        new classes, changes and cancellations all flow in.
      </p>

      {url ? (
        // Just minted — show the link once.
        <div className="mt-3">
          <p className="m-sub text-ink-2">
            Copy this link and add it to your calendar as a subscription. We only
            show it once.
          </p>
          <div className="mt-2 rounded-xl px-3 py-2.5" style={{ background: "var(--accent-chip)" }}>
            <code className="block break-all text-[12px] leading-[17px] text-ink">{url}</code>
          </div>
          <button onClick={copy}
                  className="m-tap mt-2 inline-flex items-center rounded-full px-4 text-[13px] font-bold"
                  style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
            {copied ? "Copied" : "Copy link"}
          </button>
        </div>
      ) : isActive ? (
        <div className="mt-3">
          <p className="m-sub text-ink-2">
            Your feed is on
            {lastUsed
              ? <> · last checked {new Date(lastUsed).toLocaleDateString()}</>
              : <> · not checked yet</>}.
          </p>
          <div className="mt-2 flex gap-2">
            <button onClick={mint} disabled={pending}
                    className="m-tap inline-flex items-center rounded-full px-4 text-[13px] font-bold disabled:opacity-60"
                    style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>
              Replace link
            </button>
            <button onClick={revoke} disabled={pending}
                    className="m-tap inline-flex items-center rounded-full border px-4 text-[13px] font-medium text-ink-2 disabled:opacity-60"
                    style={{ borderColor: "var(--line-2)" }}>
              Turn off
            </button>
          </div>
          <p className="m-sub mt-2 text-ink-3">
            Replacing makes a new link and kills the old one.
          </p>
        </div>
      ) : (
        <div className="mt-3">
          <button onClick={mint} disabled={pending}
                  className="m-tap inline-flex items-center rounded-full px-4 text-[13px] font-bold disabled:opacity-60"
                  style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
            {pending ? "One moment…" : "Create a feed link"}
          </button>
        </div>
      )}

      {error && (
        <p className="mt-2 text-[12px] leading-[17px] text-ink"
           style={{ borderLeft: "3px solid var(--coral)", paddingLeft: 8 }} role="alert">
          {error}
        </p>
      )}
    </div>
  );
}
