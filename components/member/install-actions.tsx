"use client";

import { useEffect, useState } from "react";

type BIPEvent = Event & { prompt: () => Promise<void>; userChoice: Promise<{ outcome: string }> };

/**
 * Decision 51 — the real install affordance where the browser offers one.
 * Chrome/Android fires `beforeinstallprompt`; we capture it and show an Install
 * button that triggers the native prompt. iOS Safari never fires it (install is
 * manual via Share → Add to Home Screen), so the button simply never appears
 * there and the written iPhone steps carry it. "Open the app" is always useful:
 * after installing, someone may still be looking at this page in a browser.
 */
export default function InstallActions({ appUrl, accentOnSolid, accentFill }: {
  appUrl: string; accentOnSolid: string; accentFill: string;
}) {
  const [deferred, setDeferred] = useState<BIPEvent | null>(null);
  const [done, setDone] = useState(false);

  useEffect(() => {
    const onBIP = (e: Event) => { e.preventDefault(); setDeferred(e as BIPEvent); };
    const onInstalled = () => { setDone(true); setDeferred(null); };
    window.addEventListener("beforeinstallprompt", onBIP);
    window.addEventListener("appinstalled", onInstalled);
    return () => {
      window.removeEventListener("beforeinstallprompt", onBIP);
      window.removeEventListener("appinstalled", onInstalled);
    };
  }, []);

  const install = async () => {
    if (!deferred) return;
    await deferred.prompt();
    await deferred.userChoice.catch(() => undefined);
    setDeferred(null);
  };

  return (
    <div className="mt-5 flex flex-col gap-2.5">
      {deferred && !done && (
        <button onClick={install}
                className="m-action flex w-full items-center justify-center rounded-xl text-[16px] font-semibold"
                style={{ background: accentFill, color: accentOnSolid }}>
          Install
        </button>
      )}
      {done && (
        <p className="m-sub text-center text-ink-2">Installed. Open it from your home screen.</p>
      )}
      <a href={appUrl}
         className="m-sub block text-center text-ink-2 underline underline-offset-4">
        Already installed? Open the app
      </a>
    </div>
  );
}
