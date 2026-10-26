"use client";

import { useEffect } from "react";

/**
 * Decision 82 — register the member host's service worker (/sw.js). Rendered
 * only from the member layout, so it never runs on the staff host. A failure is
 * swallowed: the app must work exactly the same with no service worker, so this
 * is a pure enhancement and never a dependency.
 */
export default function RegisterSW() {
  useEffect(() => {
    if (typeof navigator === "undefined" || !("serviceWorker" in navigator)) return;
    navigator.serviceWorker.register("/sw.js").catch(() => {});
  }, []);
  return null;
}
