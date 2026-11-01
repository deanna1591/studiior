"use client";

import { useEffect, useRef, useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { sendMemberMessage } from "./actions";

export type MessageRow = {
  id: string;
  mine: boolean;
  senderName: string | null;
  when: string;
  body: string;
  attachmentUrl: string | null;
  attachmentName: string | null;
};

const MIME = ["image/jpeg", "image/png", "image/webp", "application/pdf"];
const MAX = 1048576;

function SendButton() {
  const { pending } = useFormStatus();
  return (
    <button type="submit" disabled={pending}
            className="m-tap m-press shrink-0 rounded-xl px-5 text-[15px] font-semibold disabled:opacity-50"
            style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
      {pending ? "Sending…" : "Send"}
    </button>
  );
}

export default function MessagesView({
  studioId, threadId, messages,
}: {
  studioId: string; threadId: string; messages: MessageRow[];
}) {
  const [state, action] = useFormState(sendMemberMessage, null);
  const formRef = useRef<HTMLFormElement | null>(null);
  const fileRef = useRef<HTMLInputElement | null>(null);
  const [fileName, setFileName] = useState("");
  const [fileErr, setFileErr] = useState<string | null>(null);

  // Clear the box once a send succeeds.
  useEffect(() => {
    if (state?.ok) {
      formRef.current?.reset();
      setFileName(""); setFileErr(null);
    }
  }, [state]);

  function onPick() {
    const f = fileRef.current?.files?.[0];
    if (!f) { setFileName(""); setFileErr(null); return; }
    // The same two refusals the server and the RPC use, checked before upload.
    if (f.size > MAX) { setFileErr("That file is over 1 MB. Try a smaller photo or PDF."); clearFile(); return; }
    if (!MIME.includes(f.type)) { setFileErr("Photos and PDFs only."); clearFile(); return; }
    setFileErr(null); setFileName(f.name);
  }
  function clearFile() {
    if (fileRef.current) fileRef.current.value = "";
    setFileName("");
  }

  return (
    <div>
      {messages.length === 0 ? (
        <div className="m-card mb-4 p-4">
          <p className="m-sub text-ink-2">
            No messages yet. Ask us anything about your bookings, plans or the studio.
          </p>
        </div>
      ) : (
        <ul className="mb-4 space-y-3">
          {messages.map((m) => (
            <li key={m.id} className={m.mine ? "flex justify-end" : "flex justify-start"}>
              <div className="max-w-[85%] rounded-2xl px-3.5 py-2.5"
                   style={m.mine
                     ? { background: "var(--accent-chip)", color: "var(--ink)" }
                     : { background: "var(--surface)", border: "1px solid var(--line)" }}>
                <p className="m-micro mb-0.5 text-ink-3">
                  {m.mine ? "You" : (m.senderName ?? "The studio")} · {m.when}
                </p>
                <p className="m-body whitespace-pre-line text-ink">{m.body}</p>
                {m.attachmentUrl && (
                  <a href={m.attachmentUrl} target="_blank" rel="noopener noreferrer"
                     className="m-sub mt-1.5 inline-block text-ink-2 underline underline-offset-4">
                    {m.attachmentName ?? "Attachment"}
                  </a>
                )}
              </div>
            </li>
          ))}
        </ul>
      )}

      <form ref={formRef} action={action} className="m-card p-3">
        <input type="hidden" name="studio_id" value={studioId} />
        <input type="hidden" name="thread_id" value={threadId} />
        <textarea name="body" rows={3} required maxLength={2000}
                  placeholder="Write a message"
                  className="m-body w-full resize-none bg-transparent text-ink placeholder:text-ink-3 focus:outline-none" />

        <input ref={fileRef} type="file" name="attachment" onChange={onPick}
               accept="image/jpeg,image/png,image/webp,application/pdf" className="hidden" />

        <div className="mt-2 flex items-center justify-between gap-3">
          <div className="min-w-0">
            <button type="button" onClick={() => fileRef.current?.click()}
                    className="m-sub text-ink-2 underline underline-offset-4">
              Attach a photo or PDF (up to 1 MB)
            </button>
            {fileName && (
              <span className="m-micro ml-2 text-ink-3">
                {fileName} <button type="button" onClick={clearFile} className="underline">remove</button>
              </span>
            )}
          </div>
          <SendButton />
        </div>
      </form>

      {fileErr && (
        <p className="m-sub mt-3 border-l-[3px] px-3 py-2 text-ink" role="alert"
           style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}>
          {fileErr}
        </p>
      )}
      {state && !state.ok && state.error && (
        <p className="m-sub mt-3 border-l-[3px] px-3 py-2 text-ink" role="alert"
           style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}>
          {state.error}
        </p>
      )}
    </div>
  );
}
