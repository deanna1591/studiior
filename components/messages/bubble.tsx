import { Fragment } from "react";
import { accentRamp } from "@/lib/theme";
import { fmtTime, fmtDayLong, relativeDayName } from "@/lib/time";

/**
 * Decision 89 (a) — the shared message thread, used by the member app and the
 * staff thread page so one set of chat conventions holds on both sides.
 *
 * BY PARTY, not by "me": the member's bubbles sit left in grey, the studio's
 * sit right in the studio accent — the same whoever is reading. No sender name
 * on each bubble; the time alone sits small at the bottom-right inside the
 * bubble (the studio clock); the date shows once as a centred divider between
 * days ("Today" / "Yesterday" / else "Monday 2 November", in the studio zone).
 *
 * Pure — accentRamp and the time helpers are the only dependencies, both safe
 * on the server and in the client bundle, so the member view (a client
 * component) and the staff page (a server component) share it unchanged. The
 * studio-bubble colour is the real studio accent on both sides, carried in two
 * CSS variables set on the wrapper (the staff app is otherwise unthemed).
 */
export type ThreadMessage = {
  id: string;
  sender_kind: "member" | "staff";
  body: string | null;
  created_at: string;
  attachment_path: string | null;
  attachment_name: string | null;
  attachment_mime: string | null;
};

function isImage(m: ThreadMessage): boolean {
  if (m.attachment_mime) return m.attachment_mime.startsWith("image/");
  const n = (m.attachment_name ?? m.attachment_path ?? "").toLowerCase();
  return /\.(jpe?g|png|webp|gif)$/.test(n);
}

export default function MessageThread({
  messages, tz, timeFormat, accent, signedUrls,
}: {
  messages: ThreadMessage[];
  tz: string;
  timeFormat: "12h" | "24h";
  accent: string | null;
  signedUrls: Record<string, string>;
}) {
  // A real studio accent → its measured solid/on-solid pair; no accent → the
  // preset neutral (accentRamp falls back when the string is not a hex).
  const ramp = accentRamp(accent ?? "", "warm");
  const wrap = { ["--msg-bg" as string]: ramp.solid, ["--msg-fg" as string]: ramp.onSolid } as React.CSSProperties;
  let lastDay = "";

  return (
    <div className="flex flex-col gap-1.5" style={wrap}>
      {messages.map((m) => {
        const day = fmtDayLong(m.created_at, tz);
        const divider = day !== lastDay;
        lastDay = day;
        const studio = m.sender_kind === "staff";
        const url = m.attachment_path ? signedUrls[m.attachment_path] : undefined;
        const img = isImage(m);
        return (
          <Fragment key={m.id}>
            {divider && (
              <div className="my-2 flex justify-center">
                <span className="rounded-full px-2.5 py-0.5 text-[11px] text-ink-2"
                      style={{ background: "color-mix(in srgb, var(--ink) 6%, var(--surface))" }}>
                  {relativeDayName(m.created_at, tz) ?? day}
                </span>
              </div>
            )}
            <div className={`flex ${studio ? "justify-end" : "justify-start"}`}>
              <div className="max-w-[80%] rounded-2xl px-3 py-2"
                   style={studio
                     ? { background: "var(--msg-bg)", color: "var(--msg-fg)" }
                     : { background: "color-mix(in srgb, var(--ink) 8%, var(--surface))", color: "var(--ink)" }}>
                {url && img && (
                  <a href={url} target="_blank" rel="noopener noreferrer" className="block">
                    {/* eslint-disable-next-line @next/next/no-img-element */}
                    <img src={url} alt={m.attachment_name ?? "Photo"}
                         className="mb-1 w-full max-w-[240px] rounded-lg" />
                  </a>
                )}
                {url && !img && (
                  <a href={url} target="_blank" rel="noopener noreferrer"
                     className="mb-1 flex items-center gap-2 rounded-lg px-2.5 py-1.5 text-[13px]"
                     style={{ background: "color-mix(in srgb, currentColor 12%, transparent)" }}>
                    <span aria-hidden>📄</span>
                    <span className="min-w-0 truncate underline underline-offset-2">{m.attachment_name ?? "Attachment"}</span>
                  </a>
                )}
                {m.body && <span className="block whitespace-pre-wrap break-words text-[14px] leading-[19px]">{m.body}</span>}
                <span className="mt-0.5 block text-right text-[10px] leading-[14px]"
                      style={studio ? { color: "var(--msg-fg)" } : { color: "var(--ink-3)" }}>
                  {fmtTime(m.created_at, tz, timeFormat)}
                </span>
              </div>
            </div>
          </Fragment>
        );
      })}
    </div>
  );
}
