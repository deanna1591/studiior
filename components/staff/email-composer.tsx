"use client";

import { useEffect, useRef, useState, useTransition, type ReactNode } from "react";
import { shrinkImage } from "@/lib/image-shrink";
import { uploadEmailImage, previewEmail } from "@/app/staff/email-image-actions";

/**
 * Decision 77 / 80d — the shared email composer, used by Campaigns, the closure
 * notice, every template screen and the retention board. Subject, a plain
 * textarea with a small fixed markup (blank line = paragraph, **bold**,
 * [text](https://url), ![alt](url) via Insert image), a live preview, and "Send
 * me a test". The preview is the REAL email: the body is sent to preview_template,
 * which wraps it in the studio's own frame with a sample context and writes no
 * notification row, and the result is shown in an iframe at Mobile (375) or
 * Desktop (600) width — the hand-built React frame is gone. Everything
 * studio-specific is passed in, so every caller reuses it unchanged.
 */
export default function EmailComposer({
  subject, onSubject, body, onBody, studioName, templateKey = "campaign",
  onSendTest, previewFooter, children, actions,
  subjectPlaceholder = "What members will see first",
  bodyPlaceholder = "Plain text. Leave a blank line between paragraphs.\n\n**bold**, [a link](https://…), and Insert image for a photo.",
}: {
  subject: string;
  onSubject: (v: string) => void;
  body: string;
  onBody: (v: string) => void;
  studioName: string;
  /** The notification key to render through — defaults to the campaign frame. */
  templateKey?: string;
  /** Persist + fire the test send. Returns a sentence or an error. */
  onSendTest: () => Promise<{ sentence?: string; error?: string }>;
  /** A caption shown under the preview (unsubscribe line / closure system block). */
  previewFooter?: ReactNode;
  /** Extra compose controls under the textarea (audience filters / resume date). */
  children?: ReactNode;
  /** The caller's own send/schedule/confirm buttons. */
  actions?: ReactNode;
  subjectPlaceholder?: string;
  bodyPlaceholder?: string;
}) {
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const [uploading, setUploading] = useState(false);
  const [imgErr, setImgErr] = useState<string | null>(null);
  const [testMsg, setTestMsg] = useState<string | null>(null);
  const [testErr, setTestErr] = useState<string | null>(null);
  const [pending, start] = useTransition();

  // Decision 80d: the preview is the real frame, rendered server-side by
  // preview_template, shown in an iframe. Debounced so typing is not a request
  // per keystroke; width toggles between a phone and a desktop inbox.
  const [mode, setMode] = useState<"mobile" | "desktop">("mobile");
  const [previewHtml, setPreviewHtml] = useState<string>("");
  const [previewErr, setPreviewErr] = useState<string | null>(null);
  const [, startPreview] = useTransition();
  useEffect(() => {
    const t = setTimeout(() => {
      startPreview(async () => {
        const r = await previewEmail(templateKey, subject, body);
        if (r.error) { setPreviewErr(r.error); return; }
        setPreviewErr(null);
        setPreviewHtml(r.html ?? "");
      });
    }, 400);
    return () => clearTimeout(t);
  }, [templateKey, subject, body]);

  // Insert an ![](url) image marker at the cursor (or the end).
  const insertAtCursor = (snippet: string) => {
    const el = textareaRef.current;
    if (!el) { onBody(body + snippet); return; }
    const s = el.selectionStart ?? body.length;
    const e = el.selectionEnd ?? body.length;
    // Images sit on their own line, so pad with blank lines where needed.
    const before = body.slice(0, s);
    const after = body.slice(e);
    const padBefore = before === "" || before.endsWith("\n\n") ? "" : before.endsWith("\n") ? "\n" : "\n\n";
    const padAfter = after === "" || after.startsWith("\n\n") ? "" : after.startsWith("\n") ? "\n" : "\n\n";
    onBody(before + padBefore + snippet + padAfter + after);
  };

  const onPick = async (file: File | null) => {
    setImgErr(null);
    if (!file) return;
    setUploading(true);
    // Egress (CLAUDE.md): an inline email image is served to every recipient
    // who loads images, so shrink it to ≤1280px before upload. An SVG passes
    // through untouched; a decode failure leaves the original.
    const small = await shrinkImage(file, { maxPx: 1280, mode: "fit" });
    const fd = new FormData();
    fd.set("image", small);
    const res = await uploadEmailImage(fd);
    setUploading(false);
    if (fileRef.current) fileRef.current.value = "";
    if (res.error || !res.url) { setImgErr(res.error ?? "Upload failed."); return; }
    insertAtCursor(`![image](${res.url})`);
  };

  const sendTest = () => {
    setTestMsg(null); setTestErr(null);
    start(async () => {
      const r = await onSendTest();
      if (r.error) setTestErr(r.error); else setTestMsg(r.sentence ?? "Test sent.");
    });
  };

  return (
    <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
      {/* Compose */}
      <div>
        <label className="block text-[12px] font-medium text-ink-2">Subject</label>
        <input
          value={subject} onChange={(e) => onSubject(e.target.value)}
          className="mt-1 w-full rounded border border-line-2 bg-surface px-3 py-2 text-[14px] text-ink"
          placeholder={subjectPlaceholder}
        />

        <div className="mt-4 flex items-center justify-between">
          <label className="block text-[12px] font-medium text-ink-2">Message</label>
          <button type="button" disabled={uploading}
            onClick={() => fileRef.current?.click()}
            className="rounded border border-line-2 bg-surface px-2.5 py-1 text-[12px] font-medium text-ink hover:bg-paper disabled:opacity-50">
            {uploading ? "Uploading…" : "Insert image"}
          </button>
          <input ref={fileRef} type="file" accept="image/png,image/jpeg,image/webp,image/svg+xml"
                 className="hidden" onChange={(e) => onPick(e.target.files?.[0] ?? null)} />
        </div>
        <textarea
          ref={textareaRef}
          value={body} onChange={(e) => onBody(e.target.value)}
          rows={10}
          className="mt-1 w-full rounded border border-line-2 bg-surface px-3 py-2 text-[14px] leading-[21px] text-ink"
          placeholder={bodyPlaceholder}
        />
        <p className="mt-1 text-[11px] leading-4 text-ink-3">
          Blank line for a new paragraph · <code>**bold**</code> · <code>[text](https://…)</code> · Insert image for a photo.
          <br />
          Blocks: <code>[Label](https://…){"{button}"}</code> a button · <code>&gt; quote — name</code> · <code>---</code> a divider ·
          a card:
          <br />
          <code>::: card</code> / <code>name: …</code> / <code>detail: …</code> / <code>price: …</code> / <code>button: Label | https://…</code> / <code>:::</code>
        </p>
        {imgErr && <p className="mt-1 text-[12px] text-coral">{imgErr}</p>}

        {children}

        <div className="mt-5 flex flex-wrap items-center gap-2">
          {actions}
          <button type="button" disabled={pending}
            onClick={sendTest}
            className="rounded border border-line-2 bg-surface px-3 py-2 text-[13px] font-medium text-ink hover:bg-paper disabled:opacity-50">
            Send me a test
          </button>
        </div>
        {testMsg && <p className="mt-3 text-[13px] text-ink">{testMsg}</p>}
        {testErr && <p className="mt-3 text-[13px] text-coral">{testErr}</p>}
      </div>

      {/* Preview — the real email, rendered through the studio's frame by
          preview_template (no notification row), at a phone or desktop width. */}
      <div>
        <div className="flex items-center justify-between">
          <span className="block text-[12px] font-medium text-ink-2">Preview</span>
          <div className="flex overflow-hidden rounded border border-line-2 text-[12px]">
            {(["mobile", "desktop"] as const).map((m) => (
              <button key={m} type="button" onClick={() => setMode(m)}
                aria-pressed={mode === m}
                className={`px-2.5 py-1 font-medium ${mode === m ? "bg-accent-chip text-ink" : "bg-surface text-ink-3 hover:text-ink"}`}>
                {m === "mobile" ? "Mobile" : "Desktop"}
              </button>
            ))}
          </div>
        </div>
        <div className="mt-1 overflow-x-auto rounded-lg bg-[#F5F5F4] p-4">
          {previewHtml
            ? <iframe title={`${studioName} email preview`} srcDoc={previewHtml} sandbox=""
                style={{ width: mode === "mobile" ? 375 : 600, height: 640, border: 0, background: "#fff" }}
                className="mx-auto block rounded" />
            : <div className="mx-auto flex items-center justify-center rounded bg-white text-[13px] text-ink-3"
                   style={{ width: mode === "mobile" ? 375 : 600, height: 640 }}>
                Your message appears here.
              </div>}
        </div>
        {previewErr && <p className="mt-2 text-[12px] text-coral">{previewErr}</p>}
        {previewFooter && (
          <div className="mt-2 rounded border border-line bg-paper px-3 py-2 text-[12px] leading-[17px] text-ink-3">
            {previewFooter}
          </div>
        )}
      </div>
    </div>
  );
}
