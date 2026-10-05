"use client";

import { useRef, useState, useTransition } from "react";
import { scanCheckIn } from "@/app/member/instructor/actions";

/**
 * Decision 35 §4 — the roster camera scan. The instructor points the phone at
 * the member's personal QR (the 8-char rotating code); it decodes with
 * `BarcodeDetector` where the browser has it, and a bundled jsQR fallback where
 * it does not (no CDN). The decoded code goes to scanCheckIn → the member is
 * checked in with method='instructor'. The typed-code box beside it stays the
 * always-works path for a camera that will not focus in a dark studio.
 */
export default function ScanCheckIn({
  studioId, occurrenceId,
}: { studioId: string; occurrenceId: string }) {
  const [open, setOpen] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [bad, setBad] = useState(false);
  const [pending, start] = useTransition();
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

  function result(r: { ok?: string; error?: string } | null) {
    if (!r) return;
    if ("error" in r && r.error) { setBad(true); setMsg(r.error); }
    else if ("ok" in r && r.ok) { setBad(false); setMsg(r.ok); }
  }

  function submit(code: string) {
    if (busyRef.current) return;
    busyRef.current = true;
    stop();
    start(async () => {
      result(await scanCheckIn(studioId, occurrenceId, code));
      busyRef.current = false;
    });
  }

  async function go() {
    setMsg(null); setBad(false);
    let stream: MediaStream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } });
    } catch {
      setBad(true);
      setMsg("Couldn't open the camera — type the code instead.");
      return;
    }
    streamRef.current = stream;
    setOpen(true);
    busyRef.current = false;
    const video = videoRef.current!;
    video.srcObject = stream;
    await video.play().catch(() => {});

    // BarcodeDetector where available; jsQR (bundled) otherwise.
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
            if (found[0]?.rawValue) { submit(found[0].rawValue); return; }
          } else if (decode) {
            canvas.width = video.videoWidth; canvas.height = video.videoHeight;
            const cx = canvas.getContext("2d")!;
            cx.drawImage(video, 0, 0, canvas.width, canvas.height);
            const img = cx.getImageData(0, 0, canvas.width, canvas.height);
            const code = decode(img.data, img.width, img.height);
            if (code) { submit(code); return; }
          }
        } catch { /* a frame that will not decode — try the next */ }
      }
      loopRef.current = requestAnimationFrame(tick);
    }
    loopRef.current = requestAnimationFrame(tick);
  }

  return (
    <div className="m-card mb-3 px-3 py-3">
      <div className="flex items-center justify-between gap-3">
        <p className="text-[14px] font-semibold text-ink">Scan a member&rsquo;s code</p>
        {open ? (
          <button type="button" onClick={stop}
                  className="m-tap rounded-full border border-line-2 px-3 text-[13px] font-medium text-ink">
            Stop
          </button>
        ) : (
          <button type="button" onClick={go} disabled={pending}
                  className="m-tap rounded-full px-4 text-[13px] font-bold disabled:opacity-90"
                  style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
            {pending ? "Checking in…" : "Scan"}
          </button>
        )}
      </div>
      <video ref={videoRef} playsInline muted
             className={`mt-3 w-full rounded-xl bg-black ${open ? "block" : "hidden"}`}
             style={{ aspectRatio: "1 / 1", objectFit: "cover" }} />
      {open && (
        <p className="m-sub mt-2 text-ink-3">Point the camera at the member&rsquo;s check-in QR.</p>
      )}
      {msg && (
        <p className={`m-sub mt-2 ${bad ? "text-ink" : "text-ink-2"}`}
           role={bad ? "alert" : "status"}
           style={bad ? { borderLeft: "3px solid var(--coral)", paddingLeft: 8 } : undefined}>
          {msg}
        </p>
      )}
    </div>
  );
}
