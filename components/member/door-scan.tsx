"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { slugFromCheckinUrl } from "@/lib/checkin-scan";

/**
 * Decision 68 amendment — the member "Scan the studio code" door.
 *
 * Tapping Scan opens the camera (never on page load) and points it at the
 * printed studio QR (Decision 35 §3). It decodes with `BarcodeDetector` where
 * the browser has it, and a bundled jsQR fallback where it does not (no CDN) —
 * the same engine the instructor roster scanner uses. The QR encodes this
 * studio's member-host check-in URL; `slugFromCheckinUrl` accepts ONLY that
 * (the host must match this page's) and hands back the check-in token, and the
 * app navigates to /checkin/{token} — the SAME flow (window + geofence + the
 * reason sentences) without leaving the app. Anything else → the sentence.
 */
export default function DoorScan() {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const loopRef = useRef<number | null>(null);
  const busyRef = useRef(false);

  function stop() {
    if (loopRef.current !== null) cancelAnimationFrame(loopRef.current);
    loopRef.current = null;
    streamRef.current?.getTracks().forEach((t) => t.stop());
    streamRef.current = null;
    setOpen(false);
  }

  function handle(raw: string) {
    if (busyRef.current) return;
    const slug = slugFromCheckinUrl(raw, window.location.host);
    if (!slug) {
      // Not this studio's code — keep scanning, say why once.
      setMsg("That’s not this studio’s check-in code.");
      return;
    }
    busyRef.current = true;
    stop();
    // In-app navigation to the same /checkin/{slug} flow (window, geofence,
    // reasons). Never leaves the app.
    router.push(`/checkin/${slug}`);
  }

  async function go() {
    setMsg(null);
    let stream: MediaStream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } });
    } catch {
      setMsg("Couldn’t open the camera. Show your code instead, or ask at the desk.");
      return;
    }
    streamRef.current = stream;
    setOpen(true);
    busyRef.current = false;
    const video = videoRef.current!;
    video.srcObject = stream;
    await video.play().catch(() => {});

    const BD = (window as unknown as { BarcodeDetector?: new (o: { formats: string[] }) => { detect(s: CanvasImageSource): Promise<{ rawValue: string }[]> } }).BarcodeDetector;
    const detector = BD ? new BD({ formats: ["qr_code"] }) : null;
    const canvas = document.createElement("canvas");
    const decode = detector ? null : (await import("@/lib/qr-decode")).decodeQR;

    async function tick() {
      if (!streamRef.current || busyRef.current) return;
      if (video.readyState === video.HAVE_ENOUGH_DATA) {
        try {
          if (detector) {
            const found = await detector.detect(video);
            if (found[0]?.rawValue) { handle(found[0].rawValue); return; }
          } else if (decode) {
            canvas.width = video.videoWidth; canvas.height = video.videoHeight;
            const cx = canvas.getContext("2d")!;
            cx.drawImage(video, 0, 0, canvas.width, canvas.height);
            const img = cx.getImageData(0, 0, canvas.width, canvas.height);
            const code = decode(img.data, img.width, img.height);
            if (code) { handle(code); return; }
          }
        } catch { /* a frame that will not decode — try the next */ }
      }
      loopRef.current = requestAnimationFrame(tick);
    }
    loopRef.current = requestAnimationFrame(tick);
  }

  return (
    <div className="m-card p-4">
      <div className="flex items-center justify-between gap-3">
        <span className="min-w-0">
          <span className="block text-[16px] font-semibold text-ink">Scan the studio code</span>
          <span className="m-sub mt-0.5 block text-ink-2">Point your camera at the code at the door.</span>
        </span>
        {open ? (
          <button type="button" onClick={stop}
                  className="m-tap m-press shrink-0 rounded-full border border-line-2 px-4 text-[13px] font-medium text-ink">
            Stop
          </button>
        ) : (
          <button type="button" onClick={go}
                  className="m-tap m-press shrink-0 rounded-full px-5 text-[13px] font-bold"
                  style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
            Scan
          </button>
        )}
      </div>
      <video ref={videoRef} playsInline muted
             className={`mt-3 w-full rounded-xl bg-black ${open ? "block" : "hidden"}`}
             style={{ aspectRatio: "1 / 1", objectFit: "cover" }} />
      {msg && (
        <p className="m-sub mt-3 text-ink" role="alert"
           style={{ borderLeft: "3px solid var(--coral)", paddingLeft: 8 }}>
          {msg}
        </p>
      )}
    </div>
  );
}
