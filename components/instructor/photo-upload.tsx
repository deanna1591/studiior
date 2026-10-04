"use client";

import { useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { shrinkToSquare } from "@/lib/image-shrink";

export type PhotoResult = { ok: boolean; message: string };

/**
 * Decision 60 — upload an instructor's photo. Used in two places:
 *  - staff (the instructor edit page), neutral chrome;
 *  - the instructor portal Me page, the themed m-card style.
 *
 * The browser shrinks the file to a centred 800 px square JPEG BEFORE it is
 * sent (so a phone photo just works), then the server action uploads the small
 * blob and stores the public url in instructors.avatar_url. The server does the
 * storage write so RLS (the storage policy) is the boundary, not the client.
 */
export default function PhotoUpload({
  name,
  currentUrl,
  variant,
  upload,
  remove,
}: {
  name: string;
  currentUrl: string | null;
  variant: "staff" | "portal";
  upload: (fd: FormData) => Promise<PhotoResult>;
  remove: () => Promise<PhotoResult>;
}) {
  const router = useRouter();
  const [, startTransition] = useTransition();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<PhotoResult | null>(null);
  const [preview, setPreview] = useState<string | null>(currentUrl);
  const fileRef = useRef<HTMLInputElement>(null);

  const portal = variant === "portal";

  const initials = name
    .split(/\s+/).filter(Boolean).slice(0, 2)
    .map((w) => w[0]?.toUpperCase() ?? "").join("") || "?";

  async function onPick(file: File | undefined) {
    setMsg(null);
    if (!file) return;
    if (file.size > 5_242_880) {
      setMsg({ ok: false, message: "That photo is over 5 MB. Most phones can export a smaller one." });
      return;
    }
    if (!["image/png", "image/jpeg", "image/webp"].includes(file.type)) {
      setMsg({ ok: false, message: "JPEG, PNG or WebP." });
      return;
    }
    setBusy(true);
    let shrunk: File;
    try {
      shrunk = await shrinkToSquare(file, 800);
    } catch {
      setBusy(false);
      setMsg({ ok: false, message: "That photo could not be read. Try another." });
      return;
    }
    const localUrl = URL.createObjectURL(shrunk);
    const fd = new FormData();
    fd.set("photo", shrunk);
    startTransition(async () => {
      const r = await upload(fd);
      setBusy(false);
      setMsg(r);
      if (r.ok) {
        setPreview(localUrl);
        router.refresh();
      }
      if (fileRef.current) fileRef.current.value = "";
    });
  }

  function onRemove() {
    setMsg(null);
    setBusy(true);
    startTransition(async () => {
      const r = await remove();
      setBusy(false);
      setMsg(r);
      if (r.ok) {
        setPreview(null);
        router.refresh();
      }
    });
  }

  const avatar = preview ? (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src={preview}
      alt={name}
      width={64}
      height={64}
      style={{ width: 64, height: 64 }}
      className={`shrink-0 rounded-full object-cover ${portal ? "border border-line" : "border border-line"}`}
    />
  ) : (
    <span
      aria-hidden
      style={{ width: 64, height: 64, fontSize: 22 }}
      className={`flex shrink-0 items-center justify-center rounded-full border font-semibold ${
        portal ? "border-line text-ink" : "border-line bg-paper text-ink-2"
      }`}
    >
      {initials}
    </span>
  );

  const fileInputClass = portal
    ? "block w-full text-[13px] file:mr-3 file:rounded-full file:border-0 file:bg-ink file:px-3 file:py-2 file:text-[13px] file:text-surface"
    : "block w-full text-[13px] file:mr-3 file:rounded-lg file:border-0 file:bg-ink file:px-3 file:py-2 file:text-[13px] file:text-surface";

  return (
    <div className={portal ? "m-card flex items-center gap-4 p-4" : "flex items-start gap-4 rounded-lg border border-line bg-surface p-4"}>
      {avatar}
      <div className="min-w-0 flex-1">
        {msg && (
          <p
            role={msg.ok ? undefined : "alert"}
            className={`mb-1.5 text-[13px] leading-5 ${msg.ok ? "text-ink-2" : ""}`}
            style={msg.ok ? undefined : { color: "var(--coral)" }}
          >
            {msg.message}
          </p>
        )}
        <label className="block">
          <span className="sr-only">Choose a photo</span>
          <input
            ref={fileRef}
            type="file"
            accept="image/png,image/jpeg,image/webp"
            disabled={busy}
            className={fileInputClass}
            onChange={(e) => onPick(e.target.files?.[0])}
          />
        </label>
        <p className={`mt-1.5 ${portal ? "m-sub text-ink-3" : "text-xs text-ink-3"}`}>
          {busy ? "Working…" : "A square photo works best — it is shrunk and cropped for you. Up to 5 MB."}
        </p>
        {preview && (
          <button
            type="button"
            onClick={onRemove}
            disabled={busy}
            className="mt-2 text-[13px] text-ink-2 underline underline-offset-4 disabled:opacity-50"
          >
            Remove photo
          </button>
        )}
      </div>
    </div>
  );
}
