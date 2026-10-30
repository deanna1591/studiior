"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { previewBox } from "@/lib/email-preview-size";

/**
 * Decision 80 follow-up — the email preview that fits the screen.
 *
 * The email frame (render_email) is fluid: a content card at width 100% /
 * max-width 600px with a (max-width:480px) media query. So (lib/email-preview-size
 * owns the sizing, so the node test checks the shipped rule):
 *  - Mobile renders the HTML in an iframe whose width is min(375, column) — 375
 *    normally, the column when it is narrower — and the frame REFLOWS to that
 *    width; no scaling, no clipping, never wider than the column.
 *  - Desktop renders in a 600px iframe; when the column is narrower than 600 the
 *    iframe is scaled down with a CSS transform to fit, never clipped.
 * The iframe height follows its content (read from the same-origin srcdoc after
 * load, and on any reflow). sandbox is "allow-same-origin" only — no scripts run
 * in the frame, but the parent can measure it.
 */
export default function EmailPreview({ html, mode }: { html: string; mode: "mobile" | "desktop" }) {
  const wrapRef = useRef<HTMLDivElement>(null);
  const frameRef = useRef<HTMLIFrameElement>(null);
  const [paneW, setPaneW] = useState(0);
  const [contentH, setContentH] = useState(420);

  // The pane's usable width (minus its 16px padding each side), so the box can
  // be sized to fit it (0 = not measured yet).
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

  // Mobile reflows to min(375, column); desktop lays out at 600 and scales down
  // to fit. boxW <= column, so the preview never overflows (lib/email-preview-size).
  const { renderW, scale, boxW } = previewBox({ mode, avail: paneW });
  const boxH = contentH * scale;

  return (
    <div ref={wrapRef} className="mt-1 overflow-x-auto rounded-lg bg-[#F5F5F4] p-4">
      <div className="mx-auto" style={{ width: boxW, maxWidth: "100%", height: boxH }}>
        <iframe
          ref={frameRef}
          title="Email preview"
          srcDoc={html}
          sandbox="allow-same-origin"
          onLoad={measure}
          className="block rounded bg-white"
          style={{
            width: renderW,
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
