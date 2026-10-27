"use client";

import { useEffect, useRef, useState, useTransition, type ReactNode } from "react";
import { renderBody } from "@/lib/email-body";
import { shrinkImage } from "@/lib/image-shrink";
import { uploadEmailImage, emailFrameChrome, resolveEmailCard, type EmailFrameChrome, type ResolvedCard } from "@/app/staff/email-image-actions";

/**
 * Decision 77 — the shared email composer, used by Campaigns and by the closure
 * notice. Subject, a plain textarea with a small fixed markup (blank line =
 * paragraph, **bold**, [text](https://url), ![alt](url) via Insert image), a
 * live preview rendered by the ONE renderer (lib/email-body), and "Send me a
 * test". Everything studio-specific — the audience/resume controls, the send
 * buttons, the in-frame footer — is passed in, so both callers reuse it
 * unchanged.
 */
export default function EmailComposer({
  subject, onSubject, body, onBody, studioName,
  onSendTest, previewFooter, children, actions,
  subjectPlaceholder = "What members will see first",
  bodyPlaceholder = "Plain text. Leave a blank line between paragraphs.\n\n**bold**, [a link](https://…), and Insert image for a photo.",
}: {
  subject: string;
  onSubject: (v: string) => void;
  body: string;
  onBody: (v: string) => void;
  studioName: string;
  /** Persist + fire the test send. Returns a sentence or an error. */
  onSendTest: () => Promise<{ sentence?: string; error?: string }>;
  /** Shown inside the preview frame after the body (unsubscribe / system block). */
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
  // Decision 80a: the real email frame, fetched once, so the preview is the
  // email as it will send — the studio's header, accent and footer around it.
  const [chrome, setChrome] = useState<EmailFrameChrome | null>(null);
  useEffect(() => { emailFrameChrome().then(setChrome).catch(() => {}); }, []);

  // Decision 80a: resolve ::: plan <id> / ::: class <id> shorthands for the preview.
  const [cards, setCards] = useState<Record<string, ResolvedCard | null>>({});
  useEffect(() => {
    const wanted = new Set<string>();
    for (const m of body.matchAll(/^:::\s+(plan|class)\s+(\S+)\s*$/gm)) wanted.add(`${m[1]}:${m[2]}`);
    for (const key of wanted) {
      if (key in cards) continue;
      const [kind, id] = key.split(/:(.+)/);
      setCards((c) => ({ ...c, [key]: null })); // mark in-flight so we fetch once
      resolveEmailCard(kind, id).then((r) => setCards((c) => ({ ...c, [key]: r }))).catch(() => {});
    }
  }, [body, cards]);

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

  const accent = chrome?.accent || "#78716C";
  const preview = renderBody(body, {
    accent,
    resolve: (kind, id) => cards[`${kind}:${id}`] ?? null,
  });

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

      {/* Preview — the email inside the studio's real frame (header mark + accent
          rule + footer), at phone width, exactly as a recipient sees it. */}
      <div>
        <span className="block text-[12px] font-medium text-ink-2">Preview</span>
        <div className="mt-1 rounded-lg bg-[#F5F5F4] p-4">
          <div className="mx-auto max-w-[380px] overflow-hidden rounded-xl bg-white">
            <div className="px-6 pt-6">
              {chrome?.logoUrl
                ? /* eslint-disable-next-line @next/next/no-img-element */
                  <img src={chrome.logoUrl} alt="" className="h-10 w-10 rounded-md object-contain" />
                : <div className="text-[18px] font-semibold text-ink">{chrome?.studioName ?? studioName}</div>}
              <div className="mt-4 h-[3px] w-11 rounded" style={{ background: accent }} />
            </div>
            <div className="px-6 pb-2 pt-3">
              <p className="text-[15px] font-semibold text-ink">{subject || "Subject"}</p>
              {body.trim()
                ? <div className="email-preview mt-3 text-[14px] leading-[21px] text-ink"
                       dangerouslySetInnerHTML={{ __html: preview.html }} />
                : <p className="mt-3 text-[14px] text-ink-3">Your message appears here.</p>}
              {previewFooter}
            </div>
            <div className="mx-6 mt-3 border-t border-line pb-6 pt-3 text-[12px] leading-[17px] text-ink-3">
              {chrome?.contact && <div>{chrome.contact}</div>}
              {chrome?.address && <div>{chrome.address}</div>}
              <div>Choose which emails you get</div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
