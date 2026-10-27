"use client";

import { useRef, useState } from "react";
import { shrinkImage } from "@/lib/image-shrink";

/**
 * A drop-in replacement for a raw `<input type="file">` inside an existing
 * `<form action={serverAction}>`. On pick it shrinks the image in the browser
 * (lib/image-shrink) and re-assigns the input's own `.files` via DataTransfer,
 * so the enclosing form posts the SMALL blob under the SAME field name — the
 * form's action, hidden fields, focal picker and submit button are all
 * untouched. This is the egress fix: studio-branding photos and avatars were
 * uploaded raw (0.4–1.8 MB) and served full-size everywhere.
 *
 * It never fails an upload: an SVG passes through untouched, and any decode
 * error leaves the original file in place (larger, but still valid). `autoSubmit`
 * is for the desk photo control, whose label auto-submits on pick — the submit
 * has to wait for the shrink, so the component fires requestSubmit itself.
 */
export default function ShrinkImageInput({
  name,
  accept = "image/png,image/jpeg,image/webp",
  maxPx,
  mode = "fit",
  keepAlpha = false,
  autoSubmit = false,
  className,
}: {
  name: string;
  accept?: string;
  maxPx: number;
  mode?: "fit" | "square";
  keepAlpha?: boolean;
  autoSubmit?: boolean;
  className?: string;
}) {
  const ref = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);

  async function onChange() {
    const input = ref.current;
    const file = input?.files?.[0];
    if (!input || !file) return;
    if (!file.type.startsWith("image/")) {
      if (autoSubmit) input.form?.requestSubmit();
      return;
    }
    setBusy(true);
    try {
      const shrunk = await shrinkImage(file, { maxPx, mode, keepAlpha });
      if (shrunk !== file) {
        const dt = new DataTransfer();
        dt.items.add(shrunk);
        input.files = dt.files;
      }
    } catch {
      /* leave the original in place — a larger upload beats a dropped one */
    } finally {
      setBusy(false);
      if (autoSubmit) input.form?.requestSubmit();
    }
  }

  return (
    <>
      <input ref={ref} type="file" name={name} accept={accept} className={className} onChange={onChange} />
      {busy && !autoSubmit && (
        <span className="mt-1 block text-[11px] leading-4 text-ink-3">Preparing the image…</span>
      )}
    </>
  );
}
