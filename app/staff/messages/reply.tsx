"use client";

import { useEffect, useRef, useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonClass } from "@/components/ui";
import { sendStaffReply } from "./actions";

const MIME = ["image/jpeg", "image/png", "image/webp", "application/pdf"];
const MAX = 1048576;

function Send() {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Sending…" : "Send"}</button>;
}

/** Decision 89 — the studio's reply box. Same attachment rule as the member app. */
export default function StaffReply({ studioId, threadId }: { studioId: string; threadId: string }) {
  const [state, action] = useFormState(sendStaffReply, null);
  const formRef = useRef<HTMLFormElement | null>(null);
  const fileRef = useRef<HTMLInputElement | null>(null);
  const [fileName, setFileName] = useState("");
  const [fileErr, setFileErr] = useState<string | null>(null);

  useEffect(() => {
    if (state?.ok) { formRef.current?.reset(); setFileName(""); setFileErr(null); }
  }, [state]);

  function onPick() {
    const f = fileRef.current?.files?.[0];
    if (!f) { setFileName(""); setFileErr(null); return; }
    if (f.size > MAX) { setFileErr("That file is over 1 MB. Try a smaller photo or PDF."); clearFile(); return; }
    if (!MIME.includes(f.type)) { setFileErr("Photos and PDFs only."); clearFile(); return; }
    setFileErr(null); setFileName(f.name);
  }
  function clearFile() {
    if (fileRef.current) fileRef.current.value = "";
    setFileName("");
  }

  return (
    <form ref={formRef} action={action}>
      <input type="hidden" name="studio_id" value={studioId} />
      <input type="hidden" name="thread_id" value={threadId} />
      <textarea name="body" rows={3} required maxLength={2000} placeholder="Write a reply"
                className="w-full resize-none rounded border border-line bg-surface px-3 py-2 text-[13px] leading-[19px] text-ink placeholder:text-ink-3 focus:outline-none focus:ring-1 focus:ring-line" />
      <input ref={fileRef} type="file" name="attachment" onChange={onPick}
             accept="image/jpeg,image/png,image/webp,application/pdf" className="hidden" />
      <div className="mt-2 flex items-center justify-between gap-3">
        <div className="min-w-0 text-[12px]">
          <button type="button" onClick={() => fileRef.current?.click()}
                  className="text-ink-2 underline underline-offset-4">
            Attach a photo or PDF (up to 1 MB)
          </button>
          {fileName && (
            <span className="ml-2 text-ink-3">
              {fileName} <button type="button" onClick={clearFile} className="underline">remove</button>
            </span>
          )}
        </div>
        <Send />
      </div>
      {fileErr && <div className="mt-2"><Notice kind="error">{fileErr}</Notice></div>}
      {state && !state.ok && state.error && <div className="mt-2"><Notice kind="error">{state.error}</Notice></div>}
    </form>
  );
}
