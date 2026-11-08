"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { BRAND_FONT_FACES } from "@/components/staff/brand-fonts";
import type { BrandSpec } from "@/lib/brand-kit";
import {
  rangeFor, defaultDate, coreOnlyDefault, filterDays, captionText, monthCells, totalClasses,
  type PostData, type PostDay, type PostMode, type PostFormat,
} from "@/lib/schedule-post";
import { schedulePostData, uploadPostImage } from "@/app/staff/settings/marketing/actions";

const MODE_LABEL: Record<PostMode, string> = { day: "Day", week: "Week", month: "Month" };
const TITLE: Record<PostMode, string> = { day: "Today", week: "This week", month: "This month" };

/** Fetch an image URL and return a data: URL (so both preview and the PNG export
 *  carry the logo inline — no cross-origin canvas taint). Best effort. */
function useInlineImage(url: string | null): string | null {
  const [data, setData] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    setData(null);
    if (!url) return;
    (async () => {
      try {
        const r = await fetch(url, { mode: "cors" });
        if (!r.ok) return;
        const blob = await r.blob();
        const reader = new FileReader();
        reader.onload = () => { if (live) setData(reader.result as string); };
        reader.readAsDataURL(blob);
      } catch { /* fall back to the studio name */ }
    })();
    return () => { live = false; };
  }, [url]);
  return data;
}

export default function SchedulePosts({
  spec, studioName, todayIso, flexMin, canEdit,
}: {
  spec: BrandSpec;
  studioName: string;
  todayIso: string;
  flexMin: number;
  canEdit: boolean;            // desk-up may make posts; this gates upload wording only
}) {
  const [mode, setMode] = useState<PostMode>("week");
  const [dateStr, setDateStr] = useState<string>(() => defaultDate("week", todayIso));
  const [coreOnly, setCoreOnly] = useState<boolean>(() => coreOnlyDefault(flexMin));
  const [format, setFormat] = useState<PostFormat>("square");
  const [raw, setRaw] = useState<PostData | null>(null);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const postRef = useRef<HTMLDivElement>(null);

  const load = useCallback(async (m: PostMode, d: string) => {
    setLoading(true); setErr(null);
    const { from, to } = rangeFor(m, d);
    const r = await schedulePostData(from, to);
    if (r.error) { setErr(r.error); setRaw(null); }
    else setRaw(r.data ?? null);
    setLoading(false);
  }, []);

  useEffect(() => { void load(mode, dateStr); }, [mode, dateStr, load]);

  function pickMode(m: PostMode) {
    setMode(m);
    setDateStr(defaultDate(m, todayIso));
  }

  const logoData = useInlineImage(raw?.logo_url ?? null);
  const days: PostDay[] = filterDays(raw?.days ?? [], coreOnly);
  const empty = !loading && totalClasses(days) === 0;
  const rangeLabel = labelForRange(mode, dateStr, days);

  async function download() {
    const node = postRef.current;
    if (!node) return;
    setNote(null);
    try {
      const { toPng } = await import("html-to-image");
      const W = 1080, H = format === "story" ? 1920 : 1080;
      const dataUrl = await toPng(node, {
        width: W, height: H, canvasWidth: W, canvasHeight: H, pixelRatio: 1,
        backgroundColor: spec.background_treatment === "full" ? spec.colors.accent : spec.colors.background,
        style: { transform: "none", transformOrigin: "top left", margin: "0" },
        cacheBust: true,
      });
      const a = document.createElement("a");
      a.href = dataUrl;
      a.download = `${studioName.replace(/\s+/g, "-").toLowerCase()}-${mode}-${format}.png`;
      a.click();
      // Save a copy to post-images (part b will post it). Best effort.
      const blob = await (await fetch(dataUrl)).blob();
      const fd = new FormData();
      fd.set("file", new File([blob], "post.png", { type: "image/png" }));
      const up = await uploadPostImage(fd);
      setNote(up.ok ? "Downloaded and saved to your posts." : `Downloaded. ${up.error ?? "Could not save a copy."}`);
    } catch {
      setNote("Could not make the PNG. Try again.");
    }
  }

  async function copyCaption() {
    const text = captionText({ days, hashtags: raw?.hashtags ?? null });
    try { await navigator.clipboard.writeText(text); setNote("Caption copied."); }
    catch { setNote("Could not copy. Select the caption below instead."); }
  }

  const W = 1080, H = format === "story" ? 1920 : 1080;
  const PREVIEW_W = format === "story" ? 260 : 360;
  const k = PREVIEW_W / W;

  return (
    <div className="space-y-5">
      <style dangerouslySetInnerHTML={{ __html: BRAND_FONT_FACES }} />

      {/* Controls */}
      <div className="flex flex-wrap items-end gap-4">
        <Tabs value={mode} onChange={(v) => pickMode(v as PostMode)}
          options={[["day", "Day"], ["week", "Week"], ["month", "Month"]]} />
        <label className="block text-[11px] text-ink-3">Date
          <input type="date" value={dateStr} onChange={(e) => setDateStr(e.target.value)}
            className="mt-1 block rounded border border-line-2 bg-surface px-2 py-1.5 text-[13px] text-ink" />
        </label>
        <label className="flex items-center gap-2 text-[13px] text-ink-2">
          <input type="checkbox" checked={coreOnly} onChange={(e) => setCoreOnly(e.target.checked)} />
          Core classes only
        </label>
        <Tabs value={format} onChange={(v) => setFormat(v as PostFormat)}
          options={[["square", "Square 1080×1080"], ["story", "Story 1080×1920"]]} />
      </div>

      {err && <p className="text-[13px] text-coral">{err}</p>}
      {note && <p className="rounded-lg bg-lime-tint px-3 py-2 text-[13px] text-ink">{note}</p>}

      <div className="flex flex-wrap items-start gap-6">
        {/* The post, drawn at 1080 and visually scaled for preview */}
        <div style={{ width: PREVIEW_W, height: H * k, overflow: "hidden", borderRadius: 8 }}
          className="border border-line">
          <div ref={postRef} style={{ width: W, height: H, transform: `scale(${k})`, transformOrigin: "top left" }}>
            <PostInner spec={spec} days={days} mode={mode} format={format}
              rangeLabel={rangeLabel} studioName={studioName}
              logoData={logoData} footer={raw?.footer_line ?? "Book on the app"} empty={empty} loading={loading} />
          </div>
        </div>

        {/* Actions + caption */}
        <div className="min-w-[220px] flex-1 space-y-3">
          <div className="flex flex-wrap gap-3">
            <button onClick={download} disabled={empty || loading}
              className="rounded-xl px-4 py-2 text-[14px] font-semibold disabled:opacity-50"
              style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
              Download PNG
            </button>
            <button onClick={copyCaption} disabled={empty || loading}
              className="rounded-xl border border-line-2 px-4 py-2 text-[14px] text-ink disabled:opacity-50">
              Copy caption
            </button>
          </div>
          {!canEdit && <p className="text-[12px] text-ink-3">You can make and download posts; owners and managers set the footer and hashtags.</p>}
          <div>
            <p className="text-[11px] text-ink-3">Caption</p>
            <pre className="mt-1 max-h-72 overflow-auto whitespace-pre-wrap rounded-lg border border-line bg-paper p-3 text-[12px] text-ink-2">
{empty ? "No classes to post for these dates." : captionText({ days, hashtags: raw?.hashtags ?? null })}
            </pre>
          </div>
        </div>
      </div>
    </div>
  );
}

function Tabs({ value, onChange, options }: {
  value: string; onChange: (v: string) => void; options: [string, string][];
}) {
  return (
    <div className="inline-flex rounded-lg border border-line-2 p-0.5">
      {options.map(([v, label]) => (
        <button key={v} onClick={() => onChange(v)}
          className={`rounded-md px-3 py-1.5 text-[13px] ${value === v ? "bg-ink text-surface" : "text-ink-2"}`}>
          {label}
        </button>
      ))}
    </div>
  );
}

/** A month name for a range, e.g. "9–15 November" (week) or "November 2026". */
function labelForRange(mode: PostMode, dateStr: string, days: PostDay[]): string {
  const { from, to } = rangeFor(mode, dateStr);
  const d = (s: string) => new Date(`${s}T12:00:00Z`);
  if (mode === "day") {
    return days[0]?.label ?? d(from).toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "short", timeZone: "UTC" });
  }
  if (mode === "month") {
    return d(from).toLocaleDateString("en-GB", { month: "long", year: "numeric", timeZone: "UTC" });
  }
  const a = d(from), b = d(to);
  const mn = (x: Date) => x.toLocaleDateString("en-GB", { month: "long", timeZone: "UTC" });
  return a.getUTCMonth() === b.getUTCMonth()
    ? `${a.getUTCDate()}–${b.getUTCDate()} ${mn(b)}`
    : `${a.getUTCDate()} ${mn(a)} – ${b.getUTCDate()} ${mn(b)}`;
}

/** The post itself, drawn at the full 1080 base. Sizes scale with the format's
 *  height so a story post uses its extra room. */
function PostInner({
  spec, days, mode, format, rangeLabel, studioName, logoData, footer, empty, loading,
}: {
  spec: BrandSpec; days: PostDay[]; mode: PostMode; format: PostFormat;
  rangeLabel: string; studioName: string; logoData: string | null; footer: string;
  empty: boolean; loading: boolean;
}) {
  const story = format === "story";
  const W = 1080, H = story ? 1920 : 1080;
  const c = spec.colors;
  const full = spec.background_treatment === "full";
  const bg = full ? c.accent : c.background;
  const fg = full ? c.surface : c.ink;
  const muted = full ? c.surface : c.secondary;
  const cardBg = full ? "rgba(255,255,255,0.12)" : c.surface;
  const radius = spec.radius === "large" ? 40 : 14;
  const pad = 72;
  const df = `'${spec.display_font}'`, bf = `'${spec.body_font}'`;

  const logo = logoData
    ? <img src={logoData} alt="" style={{ height: 72, width: "auto", objectFit: "contain" }} />
    : <div style={{ fontFamily: df, fontWeight: 700, fontSize: 44, color: fg }}>{studioName}</div>;
  const logoRow = (
    <div style={{ display: "flex", marginBottom: 28, justifyContent: spec.logo_placement === "top-centre" ? "center" : "flex-start" }}>{logo}</div>
  );

  return (
    <div style={{
      width: W, height: H, background: bg, color: fg, position: "relative", overflow: "hidden",
      padding: pad, boxSizing: "border-box", display: "flex", flexDirection: "column",
    }}>
      {spec.background_treatment === "soft" && (
        <div style={{ position: "absolute", inset: 0, background: `linear-gradient(160deg, ${c.accent}22, transparent 70%)`, pointerEvents: "none" }} />
      )}
      {spec.logo_placement !== "bottom" && logoRow}

      <div style={{ fontFamily: df, fontWeight: 700, fontSize: story ? 84 : 72, lineHeight: 1.05 }}>{TITLE[mode]}</div>
      <div style={{ fontFamily: bf, fontSize: 34, color: muted, marginTop: 8, marginBottom: 36 }}>{rangeLabel}</div>

      <div style={{ flex: 1, minHeight: 0, overflow: "hidden" }}>
        {loading ? null : empty ? (
          <div style={{ fontFamily: bf, fontSize: 34, color: muted }}>No classes to post for these dates.</div>
        ) : mode === "day" ? (
          <DayBody days={days} df={df} bf={bf} c={c} fg={fg} muted={muted} cardBg={cardBg} radius={radius} story={story} />
        ) : mode === "week" ? (
          <WeekBody days={days} df={df} bf={bf} c={c} fg={fg} muted={muted} />
        ) : (
          <MonthBody days={days} df={df} bf={bf} c={c} fg={fg} muted={muted} cardBg={cardBg} radius={radius} />
        )}
      </div>

      {spec.logo_placement === "bottom"
        ? <div style={{ marginTop: 24 }}>{logo}</div>
        : <div style={{ fontFamily: bf, fontSize: 30, color: muted, marginTop: 24 }}>{footer}</div>}
    </div>
  );
}

type C = BrandSpec["colors"];

function DayBody({ days, df, bf, c, fg, muted, cardBg, radius, story }: {
  days: PostDay[]; df: string; bf: string; c: C; fg: string; muted: string; cardBg: string; radius: number; story: boolean;
}) {
  const classes = days[0]?.classes ?? [];
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: story ? 20 : 14 }}>
      {classes.map((cl, i) => (
        <div key={i} style={{ background: cardBg, borderRadius: Math.max(8, radius - 10), padding: "20px 26px" }}>
          <div style={{ fontFamily: bf, fontSize: 34, fontWeight: 700, color: c.accent }}>{cl.time}</div>
          <div style={{ fontFamily: df, fontSize: 44, color: fg, lineHeight: 1.1 }}>{cl.name}</div>
          {cl.coach && <div style={{ fontFamily: bf, fontSize: 28, color: muted }}>{cl.coach}</div>}
        </div>
      ))}
    </div>
  );
}

function WeekBody({ days, df, bf, c, fg, muted }: {
  days: PostDay[]; df: string; bf: string; c: C; fg: string; muted: string;
}) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 22 }}>
      {days.map((d) => (
        <div key={d.date}>
          <div style={{ fontFamily: df, fontWeight: 700, fontSize: 32, color: c.accent, marginBottom: 6 }}>{d.label}</div>
          {d.classes.map((cl, i) => (
            <div key={i} style={{ fontFamily: bf, fontSize: 30, color: fg, lineHeight: 1.35 }}>
              <span style={{ color: muted }}>{cl.time}</span>{"  "}{cl.name}{cl.coach ? ` · ${cl.coach}` : ""}
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}

function MonthBody({ days, df, bf, c, fg, muted, cardBg, radius }: {
  days: PostDay[]; df: string; bf: string; c: C; fg: string; muted: string; cardBg: string; radius: number;
}) {
  const cells = monthCells(days, 3);
  return (
    <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 16 }}>
      {cells.map((cell) => (
        <div key={cell.date} style={{ background: cardBg, borderRadius: Math.max(8, radius - 12), padding: "16px 18px" }}>
          <div style={{ fontFamily: df, fontWeight: 700, fontSize: 26, color: fg }}>{cell.label}</div>
          <div style={{ fontFamily: bf, fontSize: 22, color: c.accent, marginBottom: 6 }}>{cell.count} {cell.count === 1 ? "class" : "classes"}</div>
          {cell.first.map((n, i) => (
            <div key={i} style={{ fontFamily: bf, fontSize: 20, color: muted, lineHeight: 1.3, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{n}</div>
          ))}
          {cell.more > 0 && <div style={{ fontFamily: bf, fontSize: 20, color: muted }}>+{cell.more} more</div>}
        </div>
      ))}
    </div>
  );
}
