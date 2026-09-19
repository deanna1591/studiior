"use client";

import { useEffect, useRef, useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { signWaiver, type SignResult } from "@/app/member/waiver/actions";

/**
 * Decision 34 — the phone-first signing screen. The member reads the whole
 * waiver (Sign is disabled until they reach the end), draws a signature on a
 * canvas (finger or stylus), and signs. The name is pre-filled from the member
 * row and is not editable here — the signature is tied to the person the studio
 * knows. The server builds the signed PDF and records it.
 */
function SignButton({ enabled }: { enabled: boolean }) {
  const { pending } = useFormStatus();
  return (
    <button type="submit" disabled={!enabled || pending}
            className="m-action m-press w-full rounded-xl px-4 text-[16px] font-semibold disabled:opacity-50"
            style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
      {pending ? "Saving your signature…" : "Sign the waiver"}
    </button>
  );
}

export default function WaiverSign({
  versionId, format, body, pdfUrl, memberName,
}: {
  versionId: string; format: string; body: string | null; pdfUrl: string | null; memberName: string;
}) {
  const [state, action] = useFormState<SignResult, FormData>(signWaiver, null);
  const [reachedEnd, setReachedEnd] = useState(false);
  const [hasInk, setHasInk] = useState(false);
  const [sig, setSig] = useState("");
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const drawing = useRef(false);

  // Prepare the canvas at device resolution so the stroke is crisp.
  useEffect(() => {
    const c = canvasRef.current;
    if (!c) return;
    const dpr = window.devicePixelRatio || 1;
    const rect = c.getBoundingClientRect();
    c.width = rect.width * dpr;
    c.height = rect.height * dpr;
    const g = c.getContext("2d");
    if (g) {
      g.scale(dpr, dpr);
      g.lineWidth = 2.4; g.lineCap = "round"; g.lineJoin = "round";
      g.strokeStyle = "#1a1512";
    }
  }, []);

  function pos(e: React.PointerEvent) {
    const c = canvasRef.current!;
    const r = c.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  }
  function down(e: React.PointerEvent) {
    e.preventDefault();
    drawing.current = true;
    const g = canvasRef.current!.getContext("2d")!;
    const p = pos(e);
    g.beginPath(); g.moveTo(p.x, p.y);
    canvasRef.current!.setPointerCapture(e.pointerId);
  }
  function move(e: React.PointerEvent) {
    if (!drawing.current) return;
    const g = canvasRef.current!.getContext("2d")!;
    const p = pos(e);
    g.lineTo(p.x, p.y); g.stroke();
    if (!hasInk) setHasInk(true);
  }
  function up() {
    if (!drawing.current) return;
    drawing.current = false;
    setSig(canvasRef.current!.toDataURL("image/png"));
  }
  function clearSig() {
    const c = canvasRef.current!;
    c.getContext("2d")!.clearRect(0, 0, c.width, c.height);
    setHasInk(false); setSig("");
  }

  function onScroll(e: React.UIEvent<HTMLDivElement>) {
    const el = e.currentTarget;
    if (el.scrollHeight - el.scrollTop - el.clientHeight < 24) setReachedEnd(true);
  }

  if (state?.ok) {
    return (
      <div className="m-card p-4" role="status">
        <p className="m-name text-ink">Signed — thank you.</p>
        <p className="m-sub mt-1 text-ink-2">Your place is confirmed and your signed waiver is on file.</p>
      </div>
    );
  }

  return (
    <form action={action}>
      <input type="hidden" name="version_id" value={versionId} />
      <input type="hidden" name="signature" value={sig} />

      {/* The waiver content. Sign stays disabled until it is read to the end. */}
      {format === "text" ? (
        <div onScroll={onScroll}
             className="m-card mb-3 max-h-[46vh] overflow-y-auto whitespace-pre-line p-4 text-[14px] leading-6 text-ink-2">
          {body}
          <p className="mt-4 text-[12px] text-ink-3">— end of waiver —</p>
        </div>
      ) : (
        <div className="mb-3">
          <iframe title="Waiver" src={pdfUrl ?? ""} className="m-card h-[46vh] w-full" />
          <label className="m-sub mt-2 flex items-center gap-2 text-ink-2">
            <input type="checkbox" onChange={(e) => setReachedEnd(e.currentTarget.checked)} />
            I have read the waiver in full.
          </label>
        </div>
      )}
      {!reachedEnd && format === "text" && (
        <p className="m-sub mb-3 text-ink-3">Scroll to the end to continue.</p>
      )}

      {/* Name, pre-filled and locked. */}
      <div className="m-card mb-3 px-4 py-3">
        <p className="m-micro text-ink-3">Signing as</p>
        <p className="text-[15px] font-medium leading-5 text-ink">{memberName}</p>
      </div>

      {/* The signature pad. */}
      <div className="m-card mb-3 p-3">
        <div className="mb-1 flex items-center justify-between">
          <p className="m-micro text-ink-3">Draw your signature</p>
          {hasInk && (
            <button type="button" onClick={clearSig}
                    className="m-sub text-ink-2 underline underline-offset-4">Clear</button>
          )}
        </div>
        <canvas ref={canvasRef}
                onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerLeave={up}
                className="h-40 w-full touch-none rounded-lg"
                style={{ background: "var(--surface)", border: "1px dashed var(--line-2)" }} />
      </div>

      {state && !state.ok && (
        <p className="m-sub mb-3 border-l-[3px] px-3 py-2 text-ink" role="alert"
           style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}>
          {state.message}
        </p>
      )}

      <SignButton enabled={reachedEnd && hasInk && sig.length > 0} />
      <p className="m-micro mt-2 text-center text-ink-3">
        Signing records your name, the date, and the waiver version.
      </p>
    </form>
  );
}
