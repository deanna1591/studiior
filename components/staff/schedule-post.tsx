"use client";

import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import { BRAND_FONT_FACES } from "@/components/staff/brand-fonts";
import type { BrandSpec } from "@/lib/brand-kit";
import {
  rangeFor, defaultDate, coreOnlyDefault, filterDays, captionText, monthCells, totalClasses,
  editorialPlan, headlineParts, shortName, receiptNo,
  pushSpec, undoStack, canUndo, POST_STYLES, STYLE_LABELS,
  type PostData, type PostDay, type PostClass, type PostMode, type PostFormat, type PostStyle, type FitPage,
} from "@/lib/schedule-post";
import {
  schedulePostData, uploadPostImage, saveBrandKit, signPostImage, savePostStyle,
} from "@/app/staff/settings/marketing/actions";

type Coach = { id: string; first: string };

/** Fetch an image URL and return a data: URL (so both preview and the PNG export
 *  carry it inline — no cross-origin canvas taint). Best effort. */
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
      } catch { /* fall back */ }
    })();
    return () => { live = false; };
  }, [url]);
  return data;
}

export default function SchedulePosts({
  spec, studioName, todayIso, flexMin, canEdit, editUsed, editCap, initialStyle, coaches,
}: {
  spec: BrandSpec;
  studioName: string;
  todayIso: string;
  flexMin: number;
  canEdit: boolean;            // manager-up: may "Save as my style"
  editUsed: number;
  editCap: number;
  initialStyle: PostStyle;
  coaches: Coach[];
}) {
  const [style, setStyle] = useState<PostStyle>(initialStyle);
  const [mode, setMode] = useState<PostMode>("week");
  const [dateStr, setDateStr] = useState<string>(() => defaultDate("week", todayIso));
  const [coreOnly, setCoreOnly] = useState<boolean>(() => coreOnlyDefault(flexMin));
  const [format, setFormat] = useState<PostFormat>("square");
  const [coachId, setCoachId] = useState<string>("");          // "" = all classes
  const [raw, setRaw] = useState<PostData | null>(null);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [partIdx, setPartIdx] = useState(0);
  const postRef = useRef<HTMLDivElement>(null);

  // The edit history: base spec at index 0, each Claude edit pushed on.
  const [stack, setStack] = useState<BrandSpec[]>([spec]);
  const activeSpec = stack[stack.length - 1] ?? spec;
  const edited = stack.length > 1;
  const [used, setUsed] = useState(editUsed);
  const [instruction, setInstruction] = useState("");
  const [photo, setPhoto] = useState<File | null>(null);
  const [editing, setEditing] = useState(false);
  const [editErr, setEditErr] = useState<string | null>(null);
  const [savedNote, setSavedNote] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  // Lock screen is day only.
  const lockDayOnly = style === "lock_screen";
  useEffect(() => {
    if (lockDayOnly && mode !== "day") { setMode("day"); setDateStr(defaultDate("day", todayIso)); }
  }, [lockDayOnly, mode, todayIso]);

  const load = useCallback(async (m: PostMode, d: string, coach: string) => {
    setLoading(true); setErr(null);
    const { from, to } = rangeFor(m, d);
    const r = await schedulePostData(from, to, coach || null);
    if (r.error) { setErr(r.error); setRaw(null); }
    else setRaw(r.data ?? null);
    setLoading(false);
  }, []);

  useEffect(() => { void load(mode, dateStr, coachId); }, [mode, dateStr, coachId, load]);
  useEffect(() => { setPartIdx(0); }, [mode, dateStr, format, coreOnly, coachId, style, stack]);

  function pickMode(m: PostMode) { setMode(m); setDateStr(defaultDate(m, todayIso)); }
  function pickStyle(s: PostStyle) {
    setStyle(s);
    void savePostStyle(s);                         // best-effort persist (manager-up)
    if (s === "lock_screen" && mode !== "day") { setMode("day"); setDateStr(defaultDate("day", todayIso)); }
  }

  const logoData = useInlineImage(raw?.logo_url ?? null);
  const coachData = useInlineImage(raw?.coach_photo ?? null);

  // The Claude-edit background photo (post-images path -> signed URL -> inline).
  const [bgUrl, setBgUrl] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    const path = activeSpec.background_image ?? null;
    setBgUrl(null);
    if (!path) return;
    (async () => { const r = await signPostImage(path); if (live && r.url) setBgUrl(r.url); })();
    return () => { live = false; };
  }, [activeSpec.background_image]);
  const bgData = useInlineImage(bgUrl);

  const days: PostDay[] = filterDays(raw?.days ?? [], coreOnly);
  const empty = !loading && totalClasses(days) === 0;
  const plan = useMemo(() => editorialPlan({ days, mode, format, style }), [days, mode, format, style]);
  const page: FitPage = plan.pages[Math.min(partIdx, plan.pages.length - 1)] ?? { days, part: 1, parts: 1, scale: 1 };

  const coachFirst = raw?.coach_first ?? null;
  const { from, to } = rangeFor(mode, dateStr);
  const weekday = labelWeekday(from);
  const monthName = labelMonth(from);
  const rangeLabel = labelForRange(mode, from, to, days);

  async function download() {
    const node = postRef.current;
    if (!node) return;
    setNote(null);
    try {
      const { toPng } = await import("html-to-image");
      const W = 1080, H = format === "story" ? 1920 : 1080;
      const t = tokens(activeSpec);
      const dataUrl = await toPng(node, {
        width: W, height: H, canvasWidth: W, canvasHeight: H, pixelRatio: 1,
        backgroundColor: style === "lock_screen" ? t.ink : t.background,
        style: { transform: "none", transformOrigin: "top left", margin: "0" },
        cacheBust: true,
      });
      const partTag = page.parts > 1 ? `-part${page.part}` : "";
      const coachTag = coachFirst ? `-${coachFirst.toLowerCase()}` : "";
      const a = document.createElement("a");
      a.href = dataUrl;
      a.download = `${studioName.replace(/\s+/g, "-").toLowerCase()}-${style}-${mode}-${format}${coachTag}${partTag}.png`;
      a.click();
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
    const text = captionText({ days: page.days, hashtags: raw?.hashtags ?? null, coachFirst });
    try { await navigator.clipboard.writeText(text); setNote("Caption copied."); }
    catch { setNote("Could not copy. Select the caption below instead."); }
  }

  async function sendEdit() {
    if (!instruction.trim() || editing) return;
    setEditing(true); setEditErr(null); setSavedNote(null);
    try {
      const fd = new FormData();
      fd.set("spec", JSON.stringify(activeSpec));
      fd.set("instruction", instruction.trim());
      if (photo) fd.set("photo", photo);
      const res = await fetch("/api/staff/schedule-posts/edit", { method: "POST", body: fd });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || !data.ok) {
        setEditErr(data.error ?? "Couldn't apply that. Try saying it another way.");
      } else {
        setStack((s) => pushSpec(s, data.spec as BrandSpec));
        if (typeof data.used === "number") setUsed(data.used);
        setInstruction(""); setPhoto(null);
        if (fileRef.current) fileRef.current.value = "";
      }
    } catch {
      setEditErr("Couldn't apply that. Try saying it another way.");
    } finally {
      setEditing(false);
    }
  }

  function undo() { setStack((s) => undoStack(s).stack); setSavedNote(null); }
  async function saveStyle() {
    setSavedNote(null); setEditErr(null);
    const r = await saveBrandKit(activeSpec);
    setSavedNote(r.ok ? "Saved as your studio style." : (r.error ?? "Could not save."));
  }

  const H = format === "story" ? 1920 : 1080;
  const PREVIEW_W = format === "story" ? 260 : 360;
  const k = PREVIEW_W / 1080;
  const remaining = Math.max(0, editCap - used);

  return (
    <div className="space-y-5">
      <style dangerouslySetInnerHTML={{ __html: BRAND_FONT_FACES }} />

      {/* Style control */}
      <div>
        <p className="mb-2 text-[11px] text-ink-3">Style</p>
        <div className="flex flex-wrap gap-2">
          {POST_STYLES.map((s) => (
            <button key={s} onClick={() => pickStyle(s)}
              className={`flex items-center gap-2 rounded-lg border px-3 py-2 text-[13px] ${s === style ? "border-ink" : "border-line-2"}`}>
              <StyleThumb style={s} spec={activeSpec} />
              <span className={s === style ? "text-ink" : "text-ink-2"}>{STYLE_LABELS[s]}</span>
            </button>
          ))}
        </div>
      </div>

      {/* Controls */}
      <div className="flex flex-wrap items-end gap-4">
        <Tabs value={mode} onChange={(v) => pickMode(v as PostMode)}
          options={lockDayOnly ? [["day", "Day"]] : [["day", "Day"], ["week", "Week"], ["month", "Month"]]} />
        <label className="block text-[11px] text-ink-3">Coach
          <select value={coachId} onChange={(e) => setCoachId(e.target.value)}
            className="mt-1 block rounded border border-line-2 bg-surface px-2 py-1.5 text-[13px] text-ink">
            <option value="">All classes</option>
            {coaches.map((c) => <option key={c.id} value={c.id}>{c.first}</option>)}
          </select>
        </label>
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

      {/* Part selector when an auto-fit split happened */}
      {plan.pages.length > 1 && (
        <div className="flex items-center gap-2">
          <span className="text-[12px] text-ink-3">Too many to fit on one — split into {plan.pages.length}:</span>
          {plan.pages.map((p, i) => (
            <button key={i} onClick={() => setPartIdx(i)}
              className={`rounded-md border px-2.5 py-1 text-[12px] ${i === partIdx ? "border-ink bg-ink text-surface" : "border-line-2 text-ink-2"}`}>
              Part {p.part} of {p.parts}
            </button>
          ))}
        </div>
      )}

      <div className="flex flex-wrap items-start gap-6">
        {/* The post, drawn at 1080 and visually scaled for preview */}
        <div style={{ width: PREVIEW_W, height: H * k, overflow: "hidden", borderRadius: 8 }}
          className="border border-line">
          <div ref={postRef} style={{ width: 1080, height: H, transform: `scale(${k})`, transformOrigin: "top left" }}>
            <EditorialPost
              style={style} spec={activeSpec} page={page} mode={mode} format={format}
              studioName={studioName} logoData={logoData} coachFirst={coachFirst} coachData={coachData}
              bgData={bgData} rangeLabel={rangeLabel} weekday={weekday} monthName={monthName}
              footer={raw?.footer_line ?? "Book on the app"} empty={empty} loading={loading} />
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

          {/* Tell Claude what to change */}
          <div className="rounded-xl border border-line bg-surface p-3">
            <p className="text-[13px] font-medium text-ink">Tell Claude what to change</p>
            <textarea value={instruction} onChange={(e) => setInstruction(e.target.value)}
              rows={2} maxLength={500} disabled={empty}
              placeholder="e.g. make it darker · bigger class times · put this photo behind the classes"
              className="mt-2 block w-full rounded border border-line-2 bg-paper px-2.5 py-2 text-[13px] text-ink disabled:opacity-60" />
            <div className="mt-2 flex flex-wrap items-center gap-3">
              <button onClick={sendEdit} disabled={empty || editing || !instruction.trim()}
                className="rounded-lg px-3 py-1.5 text-[13px] font-semibold disabled:opacity-50"
                style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
                {editing ? "Applying…" : "Send"}
              </button>
              <button type="button" onClick={() => fileRef.current?.click()} disabled={empty || editing}
                className="text-[13px] text-lime-text underline disabled:opacity-50">
                {photo ? `Photo: ${photo.name}` : "Upload a photo"}
              </button>
              <input ref={fileRef} type="file" accept="image/png,image/jpeg,image/webp" className="hidden"
                onChange={(e) => setPhoto(e.target.files?.[0] ?? null)} />
              <button onClick={undo} disabled={!canUndo(stack)}
                className="text-[13px] text-ink-2 underline disabled:opacity-40">Undo</button>
              <span className="ml-auto text-[12px] text-ink-3">{used} of {editCap} edits this month</span>
            </div>
            {editErr && <p className="mt-2 text-[12px] text-coral">{editErr}</p>}
            {remaining === 0 && !editErr && <p className="mt-2 text-[12px] text-ink-3">You&rsquo;ve used all {editCap} post edits this month.</p>}

            {edited && (
              <div className="mt-3 flex flex-wrap items-center gap-3 border-t border-line pt-3">
                <span className="text-[12px] text-ink-2">Keep this look?</span>
                {canEdit && (
                  <button onClick={saveStyle}
                    className="rounded-lg border border-line-2 px-3 py-1.5 text-[13px] text-ink">Save as my style</button>
                )}
                <button onClick={() => setSavedNote("Kept for this post only.")}
                  className="rounded-lg border border-line-2 px-3 py-1.5 text-[13px] text-ink-2">Just this post</button>
                {savedNote && <span className="text-[12px] text-ink-3">{savedNote}</span>}
              </div>
            )}
          </div>

          <div>
            <p className="text-[11px] text-ink-3">Caption</p>
            <pre className="mt-1 max-h-72 overflow-auto whitespace-pre-wrap rounded-lg border border-line bg-paper p-3 text-[12px] text-ink-2">
{empty ? "No classes to post for these dates." : captionText({ days: page.days, hashtags: raw?.hashtags ?? null, coachFirst })}
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

// ---------------------------------------------------------------------------
// Date labels
// ---------------------------------------------------------------------------
function utc(s: string): Date { return new Date(`${s}T12:00:00Z`); }
function labelWeekday(iso: string): string {
  return utc(iso).toLocaleDateString("en-GB", { weekday: "long", timeZone: "UTC" });
}
function labelMonth(iso: string): string {
  return utc(iso).toLocaleDateString("en-GB", { month: "long", timeZone: "UTC" });
}
function labelForRange(mode: PostMode, from: string, to: string, days: PostDay[]): string {
  if (mode === "day") {
    return days[0]?.label ?? utc(from).toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "short", timeZone: "UTC" });
  }
  if (mode === "month") return utc(from).toLocaleDateString("en-GB", { month: "long", year: "numeric", timeZone: "UTC" });
  const a = utc(from), b = utc(to);
  const mn = (x: Date) => x.toLocaleDateString("en-GB", { month: "long", timeZone: "UTC" });
  return a.getUTCMonth() === b.getUTCMonth()
    ? `${a.getUTCDate()} to ${b.getUTCDate()} ${mn(b)}`
    : `${a.getUTCDate()} ${mn(a)} to ${b.getUTCDate()} ${mn(b)}`;
}

// ---------------------------------------------------------------------------
// Brand tokens + colour helpers
// ---------------------------------------------------------------------------
type Tokens = {
  background: string; surface: string; ink: string; accent: string; secondary: string;
  df: string; bf: string; mono: string; hand: string; onAccent: string;
};
function tokens(spec: BrandSpec): Tokens {
  const c = spec.colors;
  return {
    background: c.background, surface: c.surface, ink: c.ink, accent: c.accent, secondary: c.secondary,
    df: `'${spec.display_font}', serif`, bf: `'${spec.body_font}', sans-serif`,
    mono: "'Space Mono', monospace", hand: "'Nothing You Could Do', cursive",
    onAccent: textOn(c.accent, c.ink),
  };
}
function hex(h: string): [number, number, number] {
  const m = /^#?([0-9a-f]{6})$/i.exec(String(h || "").trim());
  if (!m) return [128, 128, 128];
  const n = parseInt(m[1], 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}
function toHex([r, g, b]: [number, number, number]): string {
  return "#" + [r, g, b].map((v) => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, "0")).join("");
}
function mixHex(a: string, b: string, t: number): string {
  const [ar, ag, ab] = hex(a), [br, bg, bb] = hex(b);
  return toHex([ar + (br - ar) * t, ag + (bg - ag) * t, ab + (bb - ab) * t]);
}
/** Readable text on an accent fill: dark ink when the accent is light, else white. */
function textOn(accent: string, ink: string): string {
  const [r, g, b] = hex(accent);
  const y = (r * 299 + g * 587 + b * 114) / 1000;
  return y >= 150 ? ink : "#FFFFFF";
}
function soft(hexColor: string, alpha: number): string {
  const [r, g, b] = hex(hexColor);
  return `rgba(${r},${g},${b},${alpha})`;
}

// ---------------------------------------------------------------------------
// Small presentational helpers
// ---------------------------------------------------------------------------
function Logo({ data, name, df, color, size }: { data: string | null; name: string; df: string; color: string; size: number }) {
  return data
    ? <img src={data} alt="" style={{ height: size, width: "auto", objectFit: "contain", maxWidth: size * 4 }} />
    : <span style={{ fontFamily: df, fontStyle: "italic", fontSize: size, color }}>{name}</span>;
}
function shortDay(label: string): string { return (label.split(/\s+/)[0] || label).slice(0, 3); }
function dayNum(date: string): string { return String(Number(date.split("-")[2] ?? "")); }
function coachNames(day: PostDay): string[] {
  return [...new Set((day.classes || []).map((c) => c.coach).filter(Boolean) as string[])].sort();
}

// ---------------------------------------------------------------------------
// The editorial post — dispatches to one of four styles
// ---------------------------------------------------------------------------
type StyleProps = {
  t: Tokens; page: FitPage; mode: PostMode; format: PostFormat;
  headline: { lead: string; accent: string }; rangeLabel: string;
  studioShort: string; logoData: string | null; coachFirst: string | null; coachData: string | null;
  footer: string; scale: number; story: boolean;
};

function EditorialPost({
  style, spec, page, mode, format, studioName, logoData, coachFirst, coachData, bgData,
  rangeLabel, weekday, monthName, footer, empty, loading,
}: {
  style: PostStyle; spec: BrandSpec; page: FitPage; mode: PostMode; format: PostFormat;
  studioName: string; logoData: string | null; coachFirst: string | null; coachData: string | null;
  bgData: string | null; rangeLabel: string; weekday: string; monthName: string;
  footer: string; empty: boolean; loading: boolean;
}) {
  const t = tokens(spec);
  const story = format === "story";
  const H = story ? 1920 : 1080;
  const studioShort = shortName(studioName);
  const headline = headlineParts({ mode, weekday, monthName, coachFirst });
  const scale = page.scale;

  if (loading) {
    return <div style={{ width: 1080, height: H, background: t.background }} />;
  }
  if (empty) {
    return (
      <div style={{ width: 1080, height: H, background: t.background, display: "flex", alignItems: "center", justifyContent: "center" }}>
        <div style={{ fontFamily: t.df, fontSize: 48, color: t.ink, textAlign: "center", maxWidth: 700 }}>No classes to post for these dates.</div>
      </div>
    );
  }

  const p: StyleProps = { t, page, mode, format, headline, rangeLabel, studioShort, logoData, coachFirst, coachData, footer, scale, story };
  const styled = style === "guest_check" ? <GuestCheck {...p} />
    : style === "times" ? <Times {...p} />
    : style === "lock_screen" ? <LockScreen {...p} />
    : <Invitation {...p} />;

  // An uploaded background photo (Claude edit) sits behind, dimmed.
  if (bgData && spec.background_image) {
    const overlay = typeof spec.overlay_strength === "number" ? spec.overlay_strength : 0.35;
    return (
      <div style={{ width: 1080, height: H, position: "relative", overflow: "hidden" }}>
        <img src={bgData} alt="" style={{ position: "absolute", inset: 0, width: "100%", height: "100%", objectFit: "cover" }} />
        <div style={{ position: "absolute", inset: 0, background: `rgba(0,0,0,${overlay})` }} />
        <div style={{ position: "absolute", inset: 0 }}>{styled}</div>
      </div>
    );
  }
  return styled;
}

function Field({ bg, children, light }: { bg: string; children: React.ReactNode; light?: boolean }) {
  const spark = light ? "rgba(255,255,255,.85)" : undefined;
  return (
    <div style={{ width: 1080, height: 1080, background: bg, display: "flex", alignItems: "center", justifyContent: "center", position: "relative", overflow: "hidden" }}>
      <div style={{ position: "absolute", left: 48, top: 40, fontSize: 70, lineHeight: 1, color: spark ?? "var(--spark)" }}>✦</div>
      <div style={{ position: "absolute", right: 60, bottom: 150, fontSize: 44, lineHeight: 1, color: spark ?? "var(--spark)" }}>✦</div>
      {children}
    </div>
  );
}

// --- Guest Check ------------------------------------------------------------
function GuestCheck(p: StyleProps) {
  const { t, page, mode, rangeLabel, studioShort, logoData, coachFirst, footer, scale, story } = p;
  const day0 = page.days[0];
  const total = page.days.reduce((n, d) => n + d.classes.length, 0);
  const cardW = story ? 840 : 700;
  const line = soft(t.secondary, 0.35);
  const metaCols = (coachFirst ? 3 : 2);
  const meta = (label: string, value: string, last?: boolean) => (
    <div style={{ fontFamily: t.mono, fontSize: 11, letterSpacing: ".15em", padding: "8px 6px", borderRight: last ? "0" : `1px solid ${t.ink}` }}>
      {label}<b style={{ display: "block", fontSize: 14, letterSpacing: 0, marginTop: 2, color: t.ink }}>{value}</b>
    </div>
  );
  return (
    <div style={{ ["--spark" as string]: t.accent, width: 1080, height: story ? 1920 : 1080, background: t.background, display: "flex", alignItems: "center", justifyContent: "center", position: "relative", overflow: "hidden" } as CSSProperties}>
      <div style={{ position: "absolute", left: 48, top: 40, fontSize: 70, color: t.accent }}>✦</div>
      <div style={{ position: "absolute", right: 60, bottom: 150, fontSize: 44, color: t.accent }}>✦</div>
      <div style={{ width: cardW, background: t.surface, padding: "44px 44px 36px", boxShadow: "0 30px 60px rgba(0,0,0,.18)", transform: story ? "rotate(-1deg)" : "rotate(-2deg)", color: t.ink }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-end", borderBottom: `2px solid ${t.ink}`, paddingBottom: 10 }}>
          <h1 style={{ fontFamily: t.df, fontWeight: 400, fontSize: 60, margin: 0, lineHeight: 1, color: t.ink }}>Guest Check</h1>
          <span style={{ fontFamily: t.mono, color: t.accent, fontWeight: 700, fontSize: 18 }}>{receiptNo(day0?.date ?? "")}</span>
        </div>
        <div style={{ display: "grid", gridTemplateColumns: `repeat(${metaCols},1fr)`, borderBottom: `2px solid ${t.ink}` }}>
          {meta(mode === "day" ? "DATE" : "WEEK", mode === "day" ? (day0?.label ?? rangeLabel) : rangeLabel)}
          {meta("CLASSES", String(total))}
          {coachFirst ? meta("COACH", coachFirst, true) : null}
        </div>
        {mode === "day"
          ? (day0?.classes ?? []).map((c, i) => (
            <div key={i} style={{ display: "grid", gridTemplateColumns: "1fr auto", gap: 10, alignItems: "end", borderBottom: `2px solid ${line}`, padding: `${Math.round(13 * scale)}px 0 ${Math.round(4 * scale)}px` }}>
              <span style={{ fontFamily: t.hand, fontSize: Math.round(31 * scale), color: t.ink }}>{c.name}</span>
              <span style={{ fontFamily: t.hand, fontSize: Math.round(24 * scale), color: c.tier === "core" ? t.accent : t.secondary }}>{c.time}{c.coach ? `, ${c.coach}` : ""}</span>
            </div>))
          : page.days.map((d) => (
            <div key={d.date} style={{ display: "grid", gridTemplateColumns: "110px 1fr", gap: 10, alignItems: "end", borderBottom: `2px solid ${line}`, padding: `${Math.round(15 * scale)}px 0 4px` }}>
              <span style={{ fontFamily: t.hand, fontSize: Math.round(30 * scale), color: t.ink }}>{shortDay(d.label)}</span>
              <span style={{ fontFamily: t.hand, fontSize: Math.round(24 * scale), color: t.secondary, textAlign: "right" }}>{d.count} {d.count === 1 ? "class" : "classes"}{coachNames(d).length ? ` · ${coachNames(d).join(", ")}` : ""}</span>
            </div>))}
        <div style={{ display: "flex", justifyContent: "space-between", borderBottom: `2px solid ${line}`, padding: "16px 0 6px", fontSize: 32, color: t.accent }}>
          <span style={{ fontFamily: t.hand }}>total:</span>
          <span style={{ fontFamily: t.hand }}>{total} {total === 1 ? "class" : "classes"}{mode === "week" ? " this week" : ""}</span>
        </div>
        <div style={{ fontFamily: t.hand, fontSize: 26, color: t.secondary, padding: "14px 0 0" }}>thank you, come again ♡</div>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-end", marginTop: 24, borderTop: `2px solid ${t.ink}`, paddingTop: 14 }}>
          <Logo data={logoData} name={studioShort} df={t.df} color={t.ink} size={40} />
          <span style={{ fontFamily: t.mono, fontSize: 12, letterSpacing: ".12em", color: t.ink }}>{footer.toUpperCase()}</span>
        </div>
      </div>
    </div>
  );
}

// --- The Times --------------------------------------------------------------
function Times(p: StyleProps) {
  const { t, page, mode, headline, rangeLabel, studioShort, logoData, footer, scale, story } = p;
  const cardW = story ? 980 : 900;
  const line = soft(t.secondary, 0.3);
  const rule = soft(t.secondary, 0.28);
  return (
    <div style={{ width: 1080, height: story ? 1920 : 1080, background: t.background, display: "flex", alignItems: "center", justifyContent: "center", position: "relative", overflow: "hidden" }}>
      <div style={{ position: "absolute", left: 48, top: 40, fontSize: 70, color: t.accent }}>✦</div>
      <div style={{ position: "absolute", right: 60, bottom: 150, fontSize: 44, color: t.accent }}>✦</div>
      <div style={{ width: cardW, background: t.surface, padding: "34px 44px", transform: story ? "rotate(0.5deg)" : "rotate(-1.2deg)", boxShadow: "0 30px 60px rgba(0,0,0,.18)", color: t.ink }}>
        <div style={{ display: "flex", justifyContent: "space-between", fontFamily: t.mono, fontSize: 13, letterSpacing: ".1em", borderBottom: `1.5px solid ${t.ink}`, paddingBottom: 8 }}>
          <span>EST. {new Date().getFullYear()}</span><span>{footer.toUpperCase()}</span><span>FREE</span>
        </div>
        <div style={{ fontFamily: t.df, fontSize: mode === "week" ? 92 : 108, textAlign: "center", lineHeight: 1, margin: "14px 0 8px" }}>The {studioShort} Times</div>
        <div style={{ textAlign: "center", fontFamily: t.mono, fontSize: 12, letterSpacing: ".3em", borderTop: `3px double ${t.ink}`, borderBottom: `1.5px solid ${t.ink}`, padding: "8px 0" }}>ALL THE CLASSES THAT ARE FIT TO PRINT</div>
        <h2 style={{ fontFamily: t.df, fontWeight: 400, fontSize: mode === "week" ? 42 : 54, lineHeight: 1.05, margin: "20px 0 14px" }}>
          {headline.lead}<em style={{ fontStyle: "italic", color: t.accent }}>{headline.accent}</em> at {studioShort}, {rangeLabel}
        </h2>
        {mode === "week" ? (
          <div style={{ display: "grid", gridTemplateColumns: "repeat(7,1fr)" }}>
            {page.days.map((d, idx) => (
              <div key={d.date} style={{ borderLeft: idx === 0 ? "0" : `1px solid ${t.ink}`, padding: idx === 0 ? "0 8px 0 0" : "0 8px" }}>
                <div style={{ fontFamily: t.df, fontSize: Math.round(24 * scale), borderBottom: `1px solid ${t.ink}`, paddingBottom: 4, marginBottom: 6 }}>{shortDay(d.label)} {dayNum(d.date)}</div>
                {d.classes.map((c, i) => (
                  <div key={i} style={{ fontSize: Math.round(12 * scale), lineHeight: 1.2, padding: "4px 0", borderBottom: `1px dotted ${line}`, color: c.tier === "core" ? t.accent : t.ink }}>
                    <b style={{ fontFamily: t.mono, fontSize: Math.round(11 * scale), display: "block", color: c.tier === "core" ? t.accent : t.secondary }}>{c.time}</b>
                    {c.name}
                    <i style={{ display: "block", fontStyle: "normal", color: t.secondary, fontSize: Math.round(11 * scale) }}>{c.coach ?? ""}</i>
                  </div>))}
              </div>))}
          </div>
        ) : mode === "month" ? (
          page.days.map((d) => (
            <div key={d.date} style={{ display: "grid", gridTemplateColumns: "150px 1fr", gap: 14, alignItems: "baseline", padding: "8px 0", borderBottom: `1px solid ${rule}` }}>
              <span style={{ fontFamily: t.df, fontSize: 28 }}>{shortDay(d.label)} {dayNum(d.date)}</span>
              <span style={{ fontSize: 18, color: t.secondary }}>{d.count} {d.count === 1 ? "class" : "classes"}{coachNames(d).length ? ` · ${coachNames(d).join(", ")}` : ""}</span>
            </div>))
        ) : (
          (page.days[0]?.classes ?? []).map((c, i) => (
            <div key={i} style={{ display: "grid", gridTemplateColumns: "140px 1fr auto", gap: 14, alignItems: "baseline", padding: `${Math.round(9 * scale)}px 0`, borderBottom: `1px solid ${rule}` }}>
              <span style={{ fontFamily: t.mono, fontSize: Math.round(16 * scale), fontWeight: 700 }}>{c.time}</span>
              <span style={{ fontFamily: t.df, fontSize: Math.round(30 * scale) }}>{c.name}</span>
              <span style={{ fontSize: Math.round(15 * scale), color: t.secondary, textAlign: "right" }}>with {c.coach ?? "the team"}{c.tier === "core" ? " · always runs" : ""}</span>
            </div>))
        )}
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-end", marginTop: 18 }}>
          <span style={{ fontFamily: t.hand, color: t.accent, fontSize: 40, transform: "rotate(-6deg)", display: "inline-block" }}>book now ♡</span>
          <Logo data={logoData} name={studioShort} df={t.df} color={t.ink} size={42} />
        </div>
      </div>
    </div>
  );
}

// --- Invitation -------------------------------------------------------------
function Invitation(p: StyleProps) {
  const { t, page, mode, headline, rangeLabel, studioShort, logoData, coachFirst, coachData, footer, scale, story } = p;
  const cardW = story ? 900 : 860;
  type Row = { icon: string; time: string; text: string; sub: string };
  const rows: Row[] = mode === "day"
    ? (page.days[0]?.classes ?? []).map((c) => ({ icon: c.tier === "core" ? "✦" : "○", time: c.time, text: c.name, sub: c.coach ? `with ${c.coach}` : "" }))
    : mode === "week"
      ? page.days.map((d) => ({ icon: "✦", time: `${shortDay(d.label)} ${dayNum(d.date)}`, text: `${d.count} ${d.count === 1 ? "class" : "classes"}`, sub: coachNames(d).length ? `· ${coachNames(d).join(", ")}` : "" }))
      : monthCells(page.days, 3).map((cell) => ({ icon: "✦", time: shortDay(cell.label), text: `${cell.count} ${cell.count === 1 ? "class" : "classes"}`, sub: cell.first.join(", ") }));
  return (
    <div style={{ width: 1080, height: story ? 1920 : 1080, background: `linear-gradient(160deg, ${t.background}, ${mixHex(t.background, t.surface, 0.5)})`, display: "flex", alignItems: "center", justifyContent: "center", position: "relative", overflow: "hidden" }}>
      <div style={{ position: "absolute", left: 48, top: 40, fontSize: 70, color: t.accent }}>✦</div>
      <div style={{ position: "absolute", right: 60, bottom: 150, fontSize: 44, color: t.accent }}>✦</div>
      <div style={{ width: cardW, background: t.surface, borderRadius: 34, overflow: "hidden", boxShadow: "0 30px 70px rgba(0,0,0,.18)" }}>
        <div style={{ background: t.accent, color: t.onAccent, display: "flex", justifyContent: "space-between", alignItems: "center", padding: "24px 40px", fontSize: 22 }}>
          <span style={{ fontFamily: t.mono, fontSize: 20 }}>{mode === "day" ? (page.days[0]?.label ?? rangeLabel) : rangeLabel}</span>
          <span style={{ display: "flex", alignItems: "center", gap: 12 }}>
            {coachData && <img src={coachData} alt="" style={{ width: 44, height: 44, borderRadius: "50%", objectFit: "cover" }} />}
            {coachFirst ?? studioShort}
          </span>
        </div>
        <div style={{ padding: "34px 44px 40px" }}>
          <h1 style={{ fontFamily: t.df, fontWeight: 400, fontSize: story ? 84 : 92, lineHeight: 0.95, margin: "0 0 24px", color: t.ink }}>
            {headline.lead}<em style={{ color: t.accent, fontStyle: "italic" }}>{headline.accent}</em>
          </h1>
          {rows.map((r, i) => (
            <div key={i} style={{ display: "flex", gap: 18, alignItems: "center", fontSize: Math.round(25 * scale), padding: `${Math.round(9 * scale)}px 0`, color: t.ink }}>
              <span style={{ color: t.accent, fontSize: Math.round(22 * scale), width: 28, textAlign: "center" }}>{r.icon}</span>
              <span><b style={{ fontFamily: t.mono, fontWeight: 700, fontSize: Math.round(20 * scale), color: t.ink, marginRight: 8 }}>{r.time}</b>{r.text} <i style={{ fontStyle: "normal", color: t.secondary }}>{r.sub}</i></span>
            </div>))}
          <div style={{ fontFamily: t.hand, fontSize: 30, color: t.secondary, margin: "22px 0 26px" }}>✦ = always runs ♡</div>
          <div style={{ display: "flex", gap: 16 }}>
            <span style={{ borderRadius: 999, padding: "18px 40px", fontSize: 24, fontWeight: 800, background: t.accent, color: t.onAccent }}>{footer}</span>
            <span style={{ borderRadius: 999, padding: "18px 40px", fontSize: 24, fontWeight: 600, border: `1.5px solid ${soft(t.secondary, 0.4)}`, color: t.secondary }}>Maybe later</span>
          </div>
        </div>
      </div>
      <div style={{ position: "absolute", right: 60, bottom: 40 }}><Logo data={logoData} name={studioShort} df={t.df} color={t.ink} size={56} /></div>
    </div>
  );
}

// --- Lock screen (day only) -------------------------------------------------
function LockScreen(p: StyleProps) {
  const { t, page, studioShort, logoData, coachFirst, coachData, footer, scale, story } = p;
  const day0 = page.days[0];
  const clock = (day0?.classes[0]?.time ?? "9:41").replace(/\s?(AM|PM)$/i, "");
  const centre = mixHex(t.accent, t.surface, 0.35);
  const edge = mixHex(t.ink, t.accent, 0.25);
  const initial = (logoData ? "" : (studioShort[0] ?? "✦")).toUpperCase();
  return (
    <div style={{ width: 1080, height: story ? 1920 : 1080, background: `radial-gradient(circle at 50% 35%, ${centre}, ${edge} 72%)`, color: "#fff", padding: "56px 70px", position: "relative", overflow: "hidden", boxSizing: "border-box" }}>
      <div style={{ textAlign: "center" }}>
        <div style={{ fontSize: 26, opacity: 0.9 }}>{day0?.label ?? ""}{coachFirst ? ` · ${coachFirst}` : ""}</div>
        <div style={{ fontFamily: t.df, fontSize: 150, lineHeight: 1, marginTop: 4 }}>{clock}</div>
      </div>
      <div style={{ marginTop: 14, display: "flex", flexDirection: "column", gap: 12 }}>
        {(day0?.classes ?? []).map((c, i) => (
          <div key={i} style={{ display: "flex", gap: 18, alignItems: "center", background: "rgba(255,255,255,.82)", color: t.ink, borderRadius: 26, padding: `${Math.round(14 * scale)}px 20px` }}>
            <div style={{ width: 60, height: 60, borderRadius: 16, overflow: "hidden", background: c.tier === "core" ? t.accent : t.surface, display: "flex", alignItems: "center", justifyContent: "center", fontFamily: t.df, fontStyle: "italic", fontSize: c.tier === "core" ? 30 : 22, color: c.tier === "core" ? t.onAccent : t.accent, flex: "0 0 auto" }}>
              {coachData ? <img src={coachData} alt="" style={{ width: "100%", height: "100%", objectFit: "cover" }} /> : (c.tier === "core" ? "✦" : (initial || "✦"))}
            </div>
            <div style={{ flex: 1 }}>
              <div style={{ display: "flex", justifyContent: "space-between", fontSize: Math.round(24 * scale) }}>
                <b style={{ fontWeight: 800 }}>{c.name}</b>
                <span style={{ color: t.secondary, fontSize: Math.round(19 * scale) }}>{c.time}</span>
              </div>
              <div style={{ fontSize: Math.round(20 * scale), color: t.secondary }}>{c.coach ? `with ${c.coach}` : ""}{c.tier === "core" ? " · always runs" : ""}</div>
            </div>
          </div>))}
      </div>
      <div style={{ textAlign: "center", marginTop: 20, fontFamily: t.hand, fontSize: 30, color: "#fff" }}>swipe up, {footer.toLowerCase()} ♡</div>
    </div>
  );
}

// --- Style thumbnail (a tiny swatch for the Style control) ------------------
function StyleThumb({ style, spec }: { style: PostStyle; spec: BrandSpec }) {
  const c = spec.colors;
  const base: CSSProperties = { width: 26, height: 26, borderRadius: 5, flex: "0 0 auto", overflow: "hidden", border: `1px solid ${soft(c.ink, 0.15)}` };
  if (style === "guest_check") return <div style={{ ...base, background: c.background, display: "flex", alignItems: "center", justifyContent: "center" }}><div style={{ width: 16, height: 20, background: c.surface }} /></div>;
  if (style === "times") return <div style={{ ...base, background: c.surface, display: "flex", flexDirection: "column", justifyContent: "center", gap: 2, padding: 3 }}><div style={{ height: 3, background: c.ink }} /><div style={{ height: 2, background: soft(c.ink, 0.5) }} /><div style={{ height: 2, background: soft(c.ink, 0.5) }} /></div>;
  if (style === "lock_screen") return <div style={{ ...base, background: `radial-gradient(circle at 50% 35%, ${mixHex(c.accent, c.surface, 0.35)}, ${mixHex(c.ink, c.accent, 0.25)} 72%)`, display: "flex", alignItems: "flex-end", padding: 3 }}><div style={{ width: "100%", height: 7, background: "rgba(255,255,255,.82)", borderRadius: 3 }} /></div>;
  return <div style={{ ...base, background: c.surface, display: "flex", flexDirection: "column" }}><div style={{ height: 8, background: c.accent }} /><div style={{ flex: 1 }} /></div>;
}
