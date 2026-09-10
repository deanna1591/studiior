"use client";

import { useEffect, useState } from "react";

/**
 * How to make the browser tab behave like an app.
 *
 * The email cannot do this — it does not know what phone is reading it, and the
 * steps are completely different. iOS only offers Add to Home Screen from
 * Safari's share sheet and refuses it in Chrome; Android offers an install
 * prompt from the browser menu. Guessing wrong sends somebody looking for a
 * button that is not there, which is exactly how "add it to your home screen"
 * becomes "this doesn't work".
 *
 * Detected on the CLIENT because the user agent is the only thing that knows,
 * and rendered as "your phone" until it does — a flash of the wrong OS is worse
 * than a moment of neither.
 */
type Platform = "ios" | "android" | "desktop" | "unknown";

export default function InstallHelp({ studioName }: { studioName: string }) {
  const [platform, setPlatform] = useState<Platform>("unknown");
  const [standalone, setStandalone] = useState(false);

  useEffect(() => {
    const ua = navigator.userAgent;
    // iPadOS 13+ reports itself as a Mac, so the touch-point count is what
    // separates an iPad from a laptop.
    const iOS = /iPad|iPhone|iPod/.test(ua)
      || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1);
    setPlatform(iOS ? "ios" : /Android/.test(ua) ? "android"
      : /Mobi/.test(ua) ? "unknown" : "desktop");
    setStandalone(
      window.matchMedia("(display-mode: standalone)").matches
      || (window.navigator as { standalone?: boolean }).standalone === true);
  }, []);

  // Already installed: saying "add it to your home screen" to somebody reading
  // this from the home screen is the same mistake in the other direction.
  if (standalone) return null;

  const steps =
    platform === "ios" ? [
      "Open this page in Safari, if you are not already",
      "Tap the Share button — the square with an arrow out of it",
      "Scroll down and tap Add to Home Screen",
    ] : platform === "android" ? [
      "Tap the ⋮ menu, top right",
      "Tap Install app, or Add to Home screen",
      "Confirm, and it appears with your other apps",
    ] : platform === "desktop" ? [
      "On your phone, open this same page",
      "Your browser's menu has Add to Home Screen or Install",
    ] : [
      "Open your browser's menu",
      "Look for Add to Home Screen or Install",
    ];

  return (
    <section className="m-card mt-6 p-4">
      <h2 className="m-head text-[15px] leading-5 text-ink">
        Put {studioName} on your home screen
      </h2>
      <p className="m-body mt-1.5 text-[13px] leading-[19px] text-ink-2">
        There is nothing to download — it is this page. Adding it to your home
        screen is what makes it open like an app, full screen and one tap away.
      </p>
      <ol className="m-body mt-2.5 list-decimal space-y-1 pl-5 text-[13px] leading-[19px] text-ink-2">
        {steps.map((s) => <li key={s}>{s}</li>)}
      </ol>
      {platform === "unknown" && (
        <p className="m-body mt-2 text-[12px] leading-4 text-ink-3">
          The exact wording depends on your browser.
        </p>
      )}
    </section>
  );
}
