"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import EmailComposer from "@/components/staff/email-composer";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveTemplateOverride, resetTemplateOverride, sendTemplateTest, setTemplateEnabled } from "@/app/staff/settings/templates/actions";

/**
 * Decision 78c — edit one notification template for this studio. The shared
 * composer renders a live preview; Save upserts the override, Reset deletes it
 * (back to the default wording), Send me a test saves then emails the caller a
 * sample. Placeholders are listed so the writer knows what will be filled in.
 */
export default function TemplateEditor({
  templateKey, label, defaultSubject, defaultBody, overrideSubject, overrideBody,
  placeholders, studioName, enabled: initialEnabled,
}: {
  templateKey: string; label: string;
  defaultSubject: string; defaultBody: string;
  overrideSubject: string | null; overrideBody: string | null;
  placeholders: string[]; studioName: string; enabled: boolean;
}) {
  const router = useRouter();
  const [subject, setSubject] = useState(overrideSubject ?? defaultSubject);
  const [body, setBody] = useState(overrideBody ?? defaultBody);
  const hasOverride = overrideSubject !== null;
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const [enabled, setEnabled] = useState(initialEnabled);
  const [togglePending, startToggle] = useTransition();

  const run = (fn: () => Promise<{ ok: true; sentence?: string } | { error: string }>) =>
    start(async () => {
      const r = await fn();
      if ("error" in r) setMsg({ ok: false, text: r.error });
      else { setMsg({ ok: true, text: r.sentence ?? "Saved." }); router.refresh(); }
    });

  const toggle = () => {
    const next = !enabled;
    startToggle(async () => {
      const r = await setTemplateEnabled(templateKey, next);
      if ("error" in r) setMsg({ ok: false, text: r.error });
      else { setEnabled(next); setMsg({ ok: true, text: r.sentence ?? "Saved." }); router.refresh(); }
    });
  };

  return (
    // Item 1: the toggle + notice stay a readable 2xl; the composer widens above
    // 1100px so its editor/preview columns have room (it caps itself when stacked).
    <div>
      <div className="max-w-2xl">
      {msg && <Notice kind={msg.ok ? "ok" : "error"}>{msg.text}</Notice>}

      <div className="mb-4 flex items-start justify-between gap-4 rounded border border-line bg-surface px-3.5 py-3">
        <span className="text-[13px] leading-[19px] text-ink">
          <span className="font-medium">Send this email</span>
          <span className="block text-[12px] leading-[18px] text-ink-3">
            {enabled
              ? "Members get this email. Switch it off to stop sending it without changing anything else."
              : "This email is off — members don't get it. Its sequence master switch, if any, still has to be on for it to send."}
          </span>
        </span>
        <button type="button" onClick={toggle} disabled={togglePending}
          aria-pressed={enabled}
          className={`shrink-0 rounded px-3 py-1.5 text-[13px] font-medium disabled:opacity-50 ${
            enabled ? "bg-accent-chip text-ink" : "border border-line-2 bg-surface text-ink-2 hover:text-ink"}`}>
          {enabled ? "On" : "Off"}
        </button>
      </div>
      </div>

      <div className="mt-4 max-w-2xl min-[1100px]:max-w-none">
      <EmailComposer
        subject={subject} onSubject={setSubject}
        body={body} onBody={setBody}
        studioName={studioName}
        templateKey={templateKey}
        onSendTest={async () => {
          const r = await sendTemplateTest(templateKey, subject, body);
          router.refresh();
          return "error" in r ? { error: r.error } : { sentence: r.sentence };
        }}
        actions={
          <div className="flex flex-wrap items-center gap-2">
            <button type="button" disabled={pending} className={buttonQuietClass}
              onClick={() => run(() => saveTemplateOverride(templateKey, subject, body))}>
              {pending ? "Saving…" : "Save"}
            </button>
            {hasOverride && (
              <button type="button" disabled={pending}
                className="rounded border border-line-2 px-3 py-1.5 text-[13px] text-ink-3 hover:text-ink"
                onClick={() => run(async () => {
                  const r = await resetTemplateOverride(templateKey);
                  if ("ok" in r) { setSubject(defaultSubject); setBody(defaultBody); }
                  return r;
                })}>
                Reset to default
              </button>
            )}
          </div>
        }
      >
        <div className="rounded border border-line bg-paper px-3 py-2.5">
          <div className="text-[12px] font-medium text-ink-2">Placeholders you can use</div>
          <div className="mt-1.5 flex flex-wrap gap-1.5">
            {placeholders.length === 0
              ? <span className="text-[12px] text-ink-3">None — this message has no fill-ins.</span>
              : placeholders.map((p) => (
                  <code key={p} className="rounded bg-surface px-1.5 py-0.5 text-[12px] text-ink-2">{`{${p}}`}</code>
                ))}
          </div>
          <p className="mt-2 text-[12px] leading-[17px] text-ink-3">
            Each is replaced with the member&rsquo;s own details when the email goes out.
            Leave one out and it simply won&rsquo;t appear.
          </p>
        </div>
      </EmailComposer>
      </div>
    </div>
  );
}
