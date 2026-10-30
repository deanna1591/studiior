"use client";

import { useCallback, useEffect, useRef, useState } from "react";

/**
 * Decision 80 follow-up — the email preview that fits the screen.
 *
 * The email frame (render_email) is fluid: a content card at width 100% /
 * max-width 600px with a (max-width:480px) media query. So:
 *  - Mobile renders the HTML in a 375px iframe and the frame REFLOWS to phone
 *    width — no scaling, no clipping (a pane narrower than 375 scrolls rather
 *    than clips).
 *  - Desktop renders in a 600px iframe; when the pane is narrower than 600 the
 *    iframe is scaled down with a CSS transform to fit, never clipped.
 * The iframe height follows its content (read from the same-origin srcdoc after
 * load, and on any reflow). sandbox is "allow-same-origin" only — no scripts run
 * in the frame, but the parent can measure it.
 */
export default function EmailPreview({ html, mode }: { html: string; mode: "mobile" | "desktop" }) {
  const wrapRef = useRef<HTMLDivElement>(null);
  const frameRef = useRef<HTMLIFrameElement>(null);
  const [paneW, setPaneW] = useState(600);
  const [contentH, setContentH] = useState(420);
  const baseW = mode === "mobile" ? 375 : 600;

  // The pane's usable width (minus its 16px padding each side), so Desktop can
  // scale to fit it.
  useEffect(() => {
    const el = wrapRef.current;
    if (!el || typeof ResizeObserver === "undefined") return;
    const read = () => setPaneW(Math.max(0, el.clientWidth - 32));
    read();
    const ro = new ResizeObserver(read);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Measure the rendered email's height from the same-origin srcdoc document.
  const measure = useCallback(() => {
    const doc = frameRef.current?.contentDocument;
    if (!doc?.body) return;
    const h = Math.max(doc.body.scrollHeight, doc.documentElement?.scrollHeight ?? 0);
    if (h > 0) setContentH(h);
  }, []);
  // Re-measure shortly after the html/mode changes (srcdoc reflows the frame).
  useEffect(() => {
    const t = setTimeout(measure, 80);
    return () => clearTimeout(t);
  }, [html, mode, measure]);

  // Desktop shrinks to fit a narrow pane; mobile is always 1:1 (and scrolls if
  // the pane is narrower than 375, so the phone layout is never clipped).
  const scale = mode === "desktop" && paneW > 0 && paneW < baseW ? paneW / baseW : 1;
  const boxW = baseW * scale;
  const boxH = contentH * scale;

  return (
    <div ref={wrapRef} className="mt-1 overflow-x-auto rounded-lg bg-[#F5F5F4] p-4">
      <div className="mx-auto" style={{ width: boxW, height: boxH }}>
        <iframe
          ref={frameRef}
          title="Email preview"
          srcDoc={html}
          sandbox="allow-same-origin"
          onLoad={measure}
          className="block rounded bg-white"
          style={{
            width: baseW,
            height: contentH,
            border: 0,
            transform: scale === 1 ? undefined : `scale(${scale})`,
            transformOrigin: "top left",
          }}
        />
      </div>
    </div>
  );
}
