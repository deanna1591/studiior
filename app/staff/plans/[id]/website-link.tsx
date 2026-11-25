"use client";

import { useRef, useState } from "react";

/**
 * Decision 57 — the website buy link for a one-time plan, with a Copy button.
 * The studio pastes this behind the "Buy" button on its own site. Clipboard
 * where available, falling back to selecting the (read-only) field so the
 * owner can copy by hand.
 */
export default function WebsiteLink({ url }: { url: string }) {
  const ref = useRef<HTMLInputElement>(null);
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(url);
    } catch {
      ref.current?.select();
      try { document.execCommand("copy"); } catch { /* leave it selected to copy by hand */ }
    }
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  return (
    <div className="mb-5 rounded border border-line bg-paper px-3 py-3">
      <p className="text-[13px] font-medium text-ink">Website link</p>
      <p className="mt-0.5 text-xs text-ink-3">
        Paste this behind the &ldquo;Buy&rdquo; button on your website.
      </p>
      <div className="mt-2 flex items-center gap-2">
        <input
          ref={ref}
          readOnly
          value={url}
          onFocus={(e) => e.currentTarget.select()}
          className="min-w-0 flex-1 rounded border border-line-2 bg-surface px-2 py-1.5 font-mono text-[12px] text-ink"
        />
        <button
          type="button"
          onClick={copy}
          className="shrink-0 rounded bg-ink px-3 py-1.5 text-[13px] font-medium text-surface"
        >
          {copied ? "Copied" : "Copy website link"}
        </button>
      </div>
    </div>
  );
}
