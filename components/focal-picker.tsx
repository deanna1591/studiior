"use client";

import { useState } from "react";

/**
 * Pick the part of a photograph that must survive the crop, on a preview at the
 * proportions it will actually be cropped to.
 *
 * THE PREVIEW SHAPE IS THE POINT. The branding screen used to show the login
 * photo in a 28px-tall full-width band — landscape, which is the one shape that
 * always looks fine and is exactly why nobody saw the problem. A 1600×600 photo
 * in a 375×812 frame keeps seventeen per cent of its width; in a wide band it
 * keeps all of it.
 *
 * Click, or drag, or use the arrow keys. The point is stored as two percentages
 * and rendered as `object-position`, so what is shown here is the same
 * arithmetic the member's phone will do.
 */
export default function FocalPicker({
  src, nameX, nameY, x: initialX, y: initialY, ratio, label, note,
}: {
  src: string;
  nameX: string; nameY: string;
  x: number; y: number;
  /** Width / height of the frame the image is cropped INTO. */
  ratio: { w: number; h: number };
  label: string;
  note?: string;
}) {
  const [x, setX] = useState(initialX);
  const [y, setY] = useState(initialY);
  const [dragging, setDragging] = useState(false);

  const put = (e: React.MouseEvent<HTMLDivElement>) => {
    const r = e.currentTarget.getBoundingClientRect();
    setX(Math.min(100, Math.max(0, Math.round(((e.clientX - r.left) / r.width) * 100))));
    setY(Math.min(100, Math.max(0, Math.round(((e.clientY - r.top) / r.height) * 100))));
  };

  const nudge = (e: React.KeyboardEvent<HTMLDivElement>) => {
    const step = e.shiftKey ? 10 : 2;
    const by = (dx: number, dy: number) => {
      e.preventDefault();
      setX((v) => Math.min(100, Math.max(0, v + dx)));
      setY((v) => Math.min(100, Math.max(0, v + dy)));
    };
    if (e.key === "ArrowLeft") by(-step, 0);
    else if (e.key === "ArrowRight") by(step, 0);
    else if (e.key === "ArrowUp") by(0, -step);
    else if (e.key === "ArrowDown") by(0, step);
  };

  return (
    <div>
      <input type="hidden" name={nameX} value={x} />
      <input type="hidden" name={nameY} value={y} />

      <span className="mb-1.5 block text-[12px] leading-4 text-ink-2">{label}</span>

      <div
        role="application"
        aria-label={`${label} — click or use the arrow keys to choose what stays in frame`}
        tabIndex={0}
        onKeyDown={nudge}
        onMouseDown={(e) => { setDragging(true); put(e); }}
        onMouseMove={(e) => { if (dragging) put(e); }}
        onMouseUp={() => setDragging(false)}
        onMouseLeave={() => setDragging(false)}
        onClick={put}
        className="relative cursor-crosshair overflow-hidden rounded border border-line
                   focus:outline-none focus:ring-2 focus:ring-ink"
        style={{ width: ratio.w / 2, height: ratio.h / 2, maxWidth: "100%" }}
      >
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src={src} alt="" aria-hidden
             className="absolute inset-0 h-full w-full object-cover"
             style={{ objectPosition: `${x}% ${y}%` }} />
        {/* The mark sits where the point IS in the source, which after cropping
            is wherever the crop put it — so it stays under the cursor and reads
            as "this is what I kept". */}
        <span aria-hidden
              className="pointer-events-none absolute h-6 w-6 -translate-x-1/2 -translate-y-1/2
                         rounded-full border-2 border-white shadow-[0_0_0_2px_rgba(20,16,14,0.55)]"
              style={{ left: "50%", top: "50%" }} />
      </div>

      <p className="mt-1.5 max-w-[46ch] text-[12px] leading-[17px] text-ink-3">
        {note ?? "This is the shape a phone crops it to."} Click the picture to say
        what has to stay in frame. Set to{" "}
        <span className="num">{x}</span>% across,{" "}
        <span className="num">{y}</span>% down.
      </p>
    </div>
  );
}
