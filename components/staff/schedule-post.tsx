"use client";

import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode, type CSSProperties } from "react";
import { BRAND_FONT_FACES } from "@/components/staff/brand-fonts";
import type { BrandSpec } from "@/lib/brand-kit";
import {
  rangeFor, defaultDate, coreOnlyDefault, filterDays, captionText, monthCells, totalClasses,
  fitPlan, pushSpec, undoStack, canUndo,
  type PostData, type PostDay, type PostMode, type PostFormat, type FitPage,
} from "@/lib/schedule-post";
import { schedulePostData, uploadPostImage, saveBrandKit, signPostImage } from "@/app/staff/settings/marketing/actions";

const TITLE: Record<PostMode, string> = { day: "Today", week: "This week", month: "This month" };

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
  spec, studioName, todayIso, flexMin, canEdit, editUsed, editCap,
}: {
  spec: BrandSpec;
  studioName: string;
  todayIso: string;
  flexMin: number;
  canEdit: boolean;            // manager-up: may "Save as my style"
  editUsed: number;
  editCap: number;
}) {
  const [mode, setMode] = useState<PostMode>("week");
  const [dateStr, setDateStr] = useState<string>(() => defaultDate("week", todayIso));
  const [coreOnly, setCoreOnly] = useState<boolean>(() => coreOnlyDefault(flexMin));
  const [format, setFormat] = useState<PostFormat>("square");
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

  const load = useCallback(async (m: PostMode, d: string) => {
    setLoading(true); setErr(null);
    const { from, to } = rangeFor(m, d);
    const r = await schedulePostData(from, to);
    if (r.error) { setErr(r.error); setRaw(null); }
    else setRaw(r.data ?? null);
    setLoading(false);
  }, []);

  useEffect(() => { void load(mode, dateStr); }, [mode, dateStr, load]);
  useEffect(() => { setPartIdx(0); }, [mode, dateStr, format, coreOnly, stack]);

  function pickMode(m: PostMode) {
    setMode(m);
    setDateStr(defaultDate(m, todayIso));
  }

  const logoData = useInlineImage(raw?.logo_url ?? null);

  // The Claude-edit background photo (post-images path -> signed URL -> inline).
  const [bgUrl, setBgUrl] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    const path = activeSpec.background_image ?? null;
    setBgUrl(null);
    if (!path) return;
    (async () => {
      const r = await signPostImage(path);
      if (live && r.url) setBgUrl(r.url);
    })();
    return () => { live = false; };
  }, [activeSpec.background_image]);
  const bgData = useInlineImage(bgUrl);

  const days: PostDay[] = filterDays(raw?.days ?? [], coreOnly);
  const empty = !loading && totalClasses(days) === 0;
  const plan = useMemo(() => fitPlan({ days, mode, format }), [days, mode, format]);
  const page: FitPage = plan.pages[Math.min(partIdx, plan.pages.length - 1)] ?? { days, part: 1, parts: 1, scale: 1 };
  const rangeLabel = labelForRange(mode, dateStr, days, page);

  async function download() {
    const node = postRef.current;
    if (!node) return;
    setNote(null);
    try {
      const { toPng } = await import("html-to-image");
      const W = 1080, H = format === "story" ? 1920 : 1080;
      const dataUrl = await toPng(node, {
        width: W, height: H, canvasWidth: W, canvasHeight: H, pixelRatio: 1,
        backgroundColor: activeSpec.background_treatment === "full" ? activeSpec.colors.accent : activeSpec.colors.background,
        style: { transform: "none", transformOrigin: "top left", margin: "0" },
        cacheBust: true,
      });
      const partTag = page.parts > 1 ? `-part${page.part}` : "";
      const a = document.createElement("a");
      a.href = dataUrl;
      a.download = `${studioName.replace(/\s+/g, "-").toLowerCase()}-${mode}-${format}${partTag}.png`;
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
    const text = captionText({ days: page.days, hashtags: raw?.hashtags ?? null });
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

  function undo() {
    setStack((s) => undoStack(s).stack);
    setSavedNote(null);
  }

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
            <PostInner spec={activeSpec} page={page} mode={mode} format={format}
              rangeLabel={rangeLabel} studioName={studioName}
              logoData={logoData} bgData={bgData} footer={raw?.footer_line ?? "Book on the app"}
              empty={empty} loading={loading} />
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
{empty ? "No classes to post for these dates." : captionText({ days: page.days, hashtags: raw?.hashtags ?? null })}
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

/** A month name for a range, with the part suffix when split. */
function labelForRange(mode: PostMode, dateStr: string, days: PostDay[], page: FitPage): string {
  const { from, to } = rangeFor(mode, dateStr);
  const d = (s: string) => new Date(`${s}T12:00:00Z`);
  let base: string;
  if (mode === "day") {
    base = days[0]?.label ?? d(from).toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "short", timeZone: "UTC" });
  } else if (mode === "month") {
    base = d(from).toLocaleDateString("en-GB", { month: "long", year: "numeric", timeZone: "UTC" });
  } else {
    const a = d(from), b = d(to);
    const mn = (x: Date) => x.toLocaleDateString("en-GB", { month: "long", timeZone: "UTC" });
    base = a.getUTCMonth() === b.getUTCMonth()
      ? `${a.getUTCDate()}–${b.getUTCDate()} ${mn(b)}`
      : `${a.getUTCDate()} ${mn(a)} – ${b.getUTCDate()} ${mn(b)}`;
  }
  return page.parts > 1 ? `${base} · part ${page.part} of ${page.parts}` : base;
}

/** The post itself, drawn at the full 1080 base. `page.scale` is the auto-fit
 *  density (font + gaps); the optional layout fields (background photo, text
 *  alignment, per-element size scale, element order) are applied here. */
function PostInner({
  spec, page, mode, format, rangeLabel, studioName, logoData, bgData, footer, empty, loading,
}: {
  spec: BrandSpec; page: FitPage; mode: PostMode; format: PostFormat;
  rangeLabel: string; studioName: string; logoData: string | null; bgData: string | null;
  footer: string; empty: boolean; loading: boolean;
}) {
  const story = format === "story";
  const W = 1080, H = story ? 1920 : 1080;
  const c = spec.colors;
  const hasPhoto = !!(spec.background_image && bgData);
  const placement = spec.image_placement ?? "full";
  const overlay = typeof spec.overlay_strength === "number" ? spec.overlay_strength : 0.45;
  const fullPhoto = hasPhoto && placement === "full";
  const full = spec.background_treatment === "full";
  const lightText = full || fullPhoto;
  const bg = full ? c.accent : c.background;
  const fg = lightText ? c.surface : c.ink;
  const muted = lightText ? c.surface : c.secondary;
  const cardBg = lightText ? "rgba(255,255,255,0.12)" : c.surface;
  const radius = spec.radius === "large" ? 40 : 14;
  const pad = 72;
  const df = `'${spec.display_font}'`, bf = `'${spec.body_font}'`;
  const align = spec.text_align ?? "left";
  const ss = spec.size_scale ?? {};
  const s = page.scale;
  const sz = (base: number, key?: "time" | "name" | "header") =>
    Math.round(base * s * (key && typeof ss[key] === "number" ? (ss[key] as number) : 1));

  const logoNode = logoData
    ? <img key="logo" src={logoData} alt="" style={{ height: 72, width: "auto", objectFit: "contain" }} />
    : <div key="logo" style={{ fontFamily: df, fontWeight: 700, fontSize: 44, color: fg }}>{studioName}</div>;
  const logoRow = (
    <div key="logo-row" style={{ display: "flex", marginBottom: 28, justifyContent: align === "center" || spec.logo_placement === "top-centre" ? "center" : "flex-start" }}>{logoNode}</div>
  );
  const titleNode = (
    <div key="title">
      <div style={{ fontFamily: df, fontWeight: 700, fontSize: sz(story ? 84 : 72, "header"), lineHeight: 1.05 }}>{TITLE[mode]}</div>
      <div style={{ fontFamily: bf, fontSize: sz(34), color: muted, marginTop: 8, marginBottom: 36 }}>{rangeLabel}</div>
    </div>
  );
  const classesNode = (
    <div key="classes" style={{ flex: 1, minHeight: 0, overflow: "hidden" }}>
      {loading ? null : empty ? (
        <div style={{ fontFamily: bf, fontSize: 34, color: muted }}>No classes to post for these dates.</div>
      ) : mode === "day" ? (
        <DayBody days={page.days} df={df} bf={bf} c={c} fg={fg} muted={muted} cardBg={cardBg} radius={radius} story={story} sz={sz} s={s} />
      ) : mode === "week" ? (
        <WeekBody days={page.days} df={df} bf={bf} c={c} fg={fg} muted={muted} sz={sz} s={s} />
      ) : (
        <MonthBody days={page.days} df={df} bf={bf} c={c} fg={fg} muted={muted} cardBg={cardBg} radius={radius} />
      )}
    </div>
  );
  const footerNode = spec.logo_placement === "bottom"
    ? <div key="footer" style={{ marginTop: 24 }}>{logoNode}</div>
    : <div key="footer" style={{ fontFamily: bf, fontSize: 30, color: muted, marginTop: 24 }}>{footer}</div>;

  // element_order controls the vertical order; default = logo(top) · title · classes · footer.
  const blocks: Record<string, ReactNode> = {
    logo: spec.logo_placement !== "bottom" ? logoRow : null,
    title: titleNode,
    classes: classesNode,
    footer: footerNode,
  };
  const order = spec.element_order && spec.element_order.length
    ? spec.element_order
    : (["logo", "title", "classes", "footer"] as const);
  const ordered = order.map((t) => blocks[t]).filter(Boolean);

  // Background photo layers (placement). The content column sits above them.
  const photoLayer = hasPhoto ? (
    placement === "full" ? (
      <>
        <img src={bgData!} alt="" style={{ position: "absolute", inset: 0, width: "100%", height: "100%", objectFit: "cover" }} />
        <div style={{ position: "absolute", inset: 0, background: `rgba(0,0,0,${overlay})` }} />
      </>
    ) : placement === "top" ? (
      <img src={bgData!} alt="" style={{ position: "absolute", top: 0, left: 0, width: "100%", height: Math.round(H * 0.42), objectFit: "cover" }} />
    ) : (
      <img src={bgData!} alt="" style={{ position: "absolute", top: 0, [placement]: 0, width: Math.round(W * 0.42), height: "100%", objectFit: "cover" } as CSSProperties} />
    )
  ) : null;

  // content padding shifts away from a side/top photo so text does not sit on it
  const contentPad: CSSProperties = {
    paddingTop: hasPhoto && placement === "top" ? Math.round(H * 0.42) + pad : pad,
    paddingBottom: pad,
    paddingLeft: hasPhoto && placement === "left" ? Math.round(W * 0.42) + pad : pad,
    paddingRight: hasPhoto && placement === "right" ? Math.round(W * 0.42) + pad : pad,
  };

  return (
    <div style={{ width: W, height: H, background: bg, color: fg, position: "relative", overflow: "hidden" }}>
      {spec.background_treatment === "soft" && !hasPhoto && (
        <div style={{ position: "absolute", inset: 0, background: `linear-gradient(160deg, ${c.accent}22, transparent 70%)`, pointerEvents: "none" }} />
      )}
      {photoLayer}
      <div style={{ position: "relative", zIndex: 1, width: "100%", height: "100%", boxSizing: "border-box", display: "flex", flexDirection: "column", textAlign: align, ...contentPad }}>
        {ordered}
      </div>
    </div>
  );
}

type C = BrandSpec["colors"];
type SZ = (base: number, key?: "time" | "name" | "header") => number;

function DayBody({ days, df, bf, c, fg, muted, cardBg, radius, story, sz, s }: {
  days: PostDay[]; df: string; bf: string; c: C; fg: string; muted: string; cardBg: string; radius: number; story: boolean; sz: SZ; s: number;
}) {
  const classes = days[0]?.classes ?? [];
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: Math.round((story ? 20 : 14) * s) }}>
      {classes.map((cl, i) => (
        <div key={i} style={{ background: cardBg, borderRadius: Math.max(8, radius - 10), padding: `${Math.round(20 * s)}px ${Math.round(26 * s)}px` }}>
          <div style={{ fontFamily: bf, fontSize: sz(34, "time"), fontWeight: 700, color: c.accent }}>{cl.time}</div>
          <div style={{ fontFamily: df, fontSize: sz(44, "name"), color: fg, lineHeight: 1.1 }}>{cl.name}</div>
          {cl.coach && <div style={{ fontFamily: bf, fontSize: sz(28), color: muted }}>{cl.coach}</div>}
        </div>
      ))}
    </div>
  );
}

function WeekBody({ days, df, bf, c, fg, muted, sz, s }: {
  days: PostDay[]; df: string; bf: string; c: C; fg: string; muted: string; sz: SZ; s: number;
}) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: Math.round(22 * s) }}>
      {days.map((d) => (
        <div key={d.date}>
          <div style={{ fontFamily: df, fontWeight: 700, fontSize: sz(32, "header"), color: c.accent, marginBottom: Math.round(6 * s) }}>{d.label}</div>
          {d.classes.map((cl, i) => (
            <div key={i} style={{ fontFamily: bf, fontSize: sz(30), color: fg, lineHeight: 1.35 }}>
              <span style={{ color: muted }}>{cl.time}</span>{"  "}{cl.name}{cl.coach ? ` with ${cl.coach}` : ""}
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
