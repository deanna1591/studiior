"use client";

import { useEffect, useState } from "react";

/**
 * A page-level toast: mounted once (so it survives a router.refresh that
 * unmounts the control that fired it). Any client component dispatches
 * `window` CustomEvent("studiior:toast", { detail: "message" }).
 */
export default function ToastHost() {
  const [msg, setMsg] = useState<string | null>(null);
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout>;
    function onToast(e: Event) {
      const detail = (e as CustomEvent).detail;
      if (typeof detail !== "string") return;
      setMsg(detail);
      clearTimeout(timer);
      timer = setTimeout(() => setMsg(null), 3500);
    }
    window.addEventListener("studiior:toast", onToast);
    return () => { window.removeEventListener("studiior:toast", onToast); clearTimeout(timer); };
  }, []);
  if (!msg) return null;
  return (
    <div className="fixed bottom-5 left-1/2 z-[60] -translate-x-1/2 rounded-full px-4 py-2 text-[13px] font-medium shadow-lg"
         style={{ background: "var(--ink)", color: "var(--surface)" }}>
      {msg}
    </div>
  );
}
