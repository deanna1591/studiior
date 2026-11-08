"use client";

import { useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import {
  BRAND_FONTS, LAYOUTS, RADII, LOGO_PLACEMENTS, BACKGROUND_TREATMENTS,
  type BrandSpec,
} from "@/lib/brand-kit";
import {
  uploadBrandReference, removeBrandReference, saveBrandKit, resetBrandKit, type BrandRef,
} from "@/app/staff/settings/marketing/actions";

// The vendored fonts (public/fonts/invoice + /brand). Family names match the spec.
const FONT_FACES = `
@font-face{font-family:'Space Grotesk';src:url('/fonts/invoice/SpaceGrotesk-Regular.ttf') format('truetype');font-weight:400;font-display:swap}
@font-face{font-family:'Space Grotesk';src:url('/fonts/invoice/SpaceGrotesk-Bold.ttf') format('truetype');font-weight:700;font-display:swap}
@font-face{font-family:'Space Mono';src:url('/fonts/invoice/SpaceMono-Regular.ttf') format('truetype');font-weight:400;font-display:swap}
@font-face{font-family:'Space Mono';src:url('/fonts/invoice/SpaceMono-Bold.ttf') format('truetype');font-weight:700;font-display:swap}
@font-face{font-family:'Bodoni Moda';src:url('/fonts/invoice/BodoniModa-Regular.ttf') format('truetype');font-weight:400;font-display:swap}
@font-face{font-family:'Instrument Serif';src:url('/fonts/brand/InstrumentSerif-Regular.ttf') format('truetype');font-weight:400;font-display:swap}
@font-face{font-family:'Playfair Display';src:url('/fonts/brand/PlayfairDisplay.ttf') format('truetype');font-weight:100 900;font-display:swap}
@font-face{font-family:'Manrope';src:url('/fonts/brand/Manrope.ttf') format('truetype');font-weight:100 900;font-display:swap}
@font-face{font-family:'Inter';src:url('/fonts/brand/Inter.ttf') format('truetype');font-weight:100 900;font-display:swap}
@font-face{font-family:'DM Sans';src:url('/fonts/brand/DMSans.ttf') format('truetype');font-weight:100 900;font-display:swap}
@font-face{font-family:'Fraunces';src:url('/fonts/brand/Fraunces.ttf') format('truetype');font-weight:100 900;font-display:swap}
@font-face{font-family:'Cormorant';src:url('/fonts/brand/Cormorant.ttf') format('truetype');font-weight:100 900;font-display:swap}
`;

const COLOR_LABELS: Record<keyof BrandSpec["colors"], string> = {
  background: "Background", surface: "Surface", ink: "Text", accent: "Accent", secondary: "Secondary",
};
const LAYOUT_LABEL: Record<string, string> = { list: "List", grid: "Day grid", poster: "Poster" };
const RADIUS_LABEL: Record<string, string> = { small: "Small corners", large: "Large corners" };
const LOGO_LABEL: Record<string, string> = { "top-left": "Logo top-left", "top-centre": "Logo top-centre", bottom: "Logo bottom" };
const BG_LABEL: Record<string, string> = { none: "Solid colour", soft: "Soft photo + overlay", full: "Full-bleed photo" };

// A fixed sample timetable so the owner sees the look before any real post.
const SAMPLE_DAY = {
  date: "Saturday 9 Nov",
  classes: [
    { time: "7:00 AM", name: "Reformer Flow", coach: "Ada" },
    { time: "9:00 AM", name: "Barre Burn", coach: "Mia" },
    { time: "5:30 PM", name: "Reformer Sculpt", coach: "Leo" },
  ],
};
const SAMPLE_WEEK = {
  range: "9–15 November",
  days: [
    { day: "Mon", items: ["7:00 Reformer Flow", "6:00 Mat Pilates"] },
    { day: "Wed", items: ["7:00 Reformer Burn"] },
    { day: "Fri", items: ["7:00 Reformer Flow"] },
    { day: "Sat", items: ["9:00 Barre Burn", "10:30 Reformer Sculpt"] },
  ],
};

export default function BrandKit({
  initial, refs: initialRefs, canEdit, studioName, logoUrl,
}: {
  initial: { spec: BrandSpec; source: string; runsUsed: number; runsCap: number };
  refs: BrandRef[];
  canEdit: boolean;
  studioName: string;
  logoUrl: string | null;
}) {
  const router = useRouter();
  const [spec, setSpec] = useState<BrandSpec>(initial.spec);
  const [source, setSource] = useState(initial.source);
  const [refs, setRefs] = useState<BrandRef[]>(initialRefs);
  const [runsUsed, setRunsUsed] = useState(initial.runsUsed);
  const [msg, setMsg] = useState<{ ok?: boolean; text: string } | null>(null);
  const [learning, setLearning] = useState(false);
  const [pending, start] = useTransition();
  const fileRef = useRef<HTMLInputElement>(null);

  const setColor = (k: keyof BrandSpec["colors"], v: string) =>
    setSpec((s) => ({ ...s, colors: { ...s.colors, [k]: v } }));
  const set = <K extends keyof BrandSpec>(k: K, v: BrandSpec[K]) => setSpec((s) => ({ ...s, [k]: v }));

  async function onUpload(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    const fd = new FormData(); fd.set("file", file);
    setMsg(null);
    start(async () => {
      const r = await uploadBrandReference(fd);
      if (r.error) setMsg({ text: r.error });
      else if (r.refs) setRefs(r.refs);
      if (fileRef.current) fileRef.current.value = "";
    });
  }
  function onRemove(name: string) {
    start(async () => {
      const r = await removeBrandReference(name);
      if (r.error) setMsg({ text: r.error });
      else if (r.refs) setRefs(r.refs);
    });
  }
  async function onLearn() {
    setMsg(null); setLearning(true);
    try {
      const res = await fetch("/api/staff/brand-kit/learn", { method: "POST" });
      const data = await res.json();
      if (res.ok && data.spec) {
        setSpec(data.spec as BrandSpec); setSource("learned");
        setRunsUsed((n) => Math.min(n + 1, initial.runsCap));
        setMsg({ ok: true, text: "Learned your style." });
      } else {
        if (res.status === 429) setRunsUsed(initial.runsCap);
        setMsg({ text: data.error ?? "Could not read the references. Try clearer exports." });
      }
    } catch {
      setMsg({ text: "Could not reach the service. Try again." });
    } finally { setLearning(false); }
  }
  function onSave() {
    setMsg(null);
    start(async () => {
      const r = await saveBrandKit(spec);
      setMsg(r.ok ? { ok: true, text: "Saved." } : { text: r.error ?? "Could not save." });
      if (r.ok) setSource("manual");
    });
  }
  function onReset() {
    setMsg(null);
    start(async () => {
      const r = await resetBrandKit();
      if (r.ok) { router.refresh(); setMsg({ ok: true, text: "Reset to studio defaults." }); }
      else setMsg({ text: r.error ?? "Could not reset." });
    });
  }

  const busy = pending || learning;

  return (
    <div className="space-y-8">
      <style dangerouslySetInnerHTML={{ __html: FONT_FACES }} />

      {msg && (
        <p className={`rounded-lg px-3 py-2 text-[13px] ${msg.ok ? "bg-lime-tint text-ink" : "text-coral"}`}>{msg.text}</p>
      )}

      {/* References + Learn */}
      <section className="space-y-3">
        <div className="flex items-baseline justify-between">
          <h2 className="text-[15px] font-semibold text-ink">Reference designs</h2>
          <span className="text-[12px] text-ink-3">{refs.length} of 5</span>
        </div>
        <p className="text-[13px] text-ink-2">Upload up to five posts you like the look of (PNG, JPG or PDF). Then learn your style.</p>
        <div className="flex flex-wrap gap-3">
          {refs.map((r) => (
            <div key={r.name} className="relative h-24 w-24 overflow-hidden rounded-lg border border-line bg-paper">
              {/\.pdf$/i.test(r.name)
                ? <div className="flex h-full w-full items-center justify-center text-[11px] text-ink-2">PDF</div>
                : <img src={r.url} alt="" className="h-full w-full object-cover" />}
              {canEdit && (
                <button onClick={() => onRemove(r.name)} disabled={busy}
                  className="absolute right-1 top-1 rounded bg-ink/70 px-1.5 text-[11px] text-surface">×</button>
              )}
            </div>
          ))}
          {canEdit && refs.length < 5 && (
            <label className="flex h-24 w-24 cursor-pointer items-center justify-center rounded-lg border border-dashed border-line-2 text-[12px] text-ink-2 hover:bg-paper">
              + Add
              <input ref={fileRef} type="file" accept="image/png,image/jpeg,application/pdf" className="hidden" onChange={onUpload} disabled={busy} />
            </label>
          )}
        </div>
        {canEdit && (
          <div className="flex items-center gap-3">
            <button onClick={onLearn} disabled={busy || refs.length === 0}
              className="rounded-xl px-4 py-2 text-[14px] font-semibold disabled:opacity-50"
              style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
              {learning ? "Learning…" : "Learn my style"}
            </button>
            <span className="num text-[12px] text-ink-3">{runsUsed} of {initial.runsCap} this month</span>
          </div>
        )}
      </section>

      {/* The spec: swatches + fonts + layout + tone */}
      <section className="space-y-3">
        <div className="flex items-baseline justify-between">
          <h2 className="text-[15px] font-semibold text-ink">Your style</h2>
          <span className="text-[12px] text-ink-3">{source === "learned" ? "Learned" : source === "manual" ? "Edited by hand" : "Studio defaults"}</span>
        </div>
        <div className="flex flex-wrap gap-4">
          {(Object.keys(COLOR_LABELS) as (keyof BrandSpec["colors"])[]).map((k) => (
            <div key={k} className="space-y-1">
              <div className="h-12 w-12 rounded-lg border border-line" style={{ background: spec.colors[k] }} />
              <div className="text-[11px] text-ink-2">{COLOR_LABELS[k]}</div>
              <div className="num text-[11px] uppercase text-ink-3">{spec.colors[k]}</div>
            </div>
          ))}
        </div>
        <div className="flex flex-wrap gap-6">
          <div>
            <div className="text-[11px] text-ink-3">Display font</div>
            <div className="text-[24px] text-ink" style={{ fontFamily: `'${spec.display_font}'` }}>{spec.display_font}</div>
          </div>
          <div>
            <div className="text-[11px] text-ink-3">Body font</div>
            <div className="text-[16px] text-ink" style={{ fontFamily: `'${spec.body_font}'` }}>The quick brown fox — {spec.body_font}</div>
          </div>
        </div>
        <p className="text-[13px] text-ink-2">
          <span className="text-ink-3">Layout:</span> {LAYOUT_LABEL[spec.layout]} · {RADIUS_LABEL[spec.radius]} · {LOGO_LABEL[spec.logo_placement]} · {BG_LABEL[spec.background_treatment]}
        </p>
        {spec.tone && <p className="text-[13px] italic text-ink-2">“{spec.tone}”</p>}
      </section>

      {/* Sample posts */}
      <section className="space-y-3">
        <h2 className="text-[15px] font-semibold text-ink">Sample posts</h2>
        <p className="text-[13px] text-ink-2">A fixed sample timetable, in your style — so you can see the look before a real post.</p>
        <div className="flex flex-wrap gap-5">
          <SamplePost spec={spec} variant="square-day" studioName={studioName} logoUrl={logoUrl} />
          <SamplePost spec={spec} variant="square-week" studioName={studioName} logoUrl={logoUrl} />
          <SamplePost spec={spec} variant="story-day" studioName={studioName} logoUrl={logoUrl} />
        </div>
      </section>

      {/* Hand overrides */}
      {canEdit && (
        <section className="space-y-4">
          <h2 className="text-[15px] font-semibold text-ink">Adjust by hand</h2>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
            {(Object.keys(COLOR_LABELS) as (keyof BrandSpec["colors"])[]).map((k) => (
              <label key={k} className="flex items-center gap-2 text-[13px] text-ink-2">
                <input type="color" value={spec.colors[k]} onChange={(e) => setColor(k, e.target.value)}
                  className="h-8 w-8 rounded border border-line" />
                {COLOR_LABELS[k]}
              </label>
            ))}
          </div>
          <div className="flex flex-wrap gap-4">
            <Field label="Display font">
              <select value={spec.display_font} onChange={(e) => set("display_font", e.target.value)} className={selCls}>
                {BRAND_FONTS.map((f) => <option key={f} value={f}>{f}</option>)}
              </select>
            </Field>
            <Field label="Body font">
              <select value={spec.body_font} onChange={(e) => set("body_font", e.target.value)} className={selCls}>
                {BRAND_FONTS.map((f) => <option key={f} value={f}>{f}</option>)}
              </select>
            </Field>
            <Field label="Layout">
              <select value={spec.layout} onChange={(e) => set("layout", e.target.value as BrandSpec["layout"])} className={selCls}>
                {LAYOUTS.map((l) => <option key={l} value={l}>{LAYOUT_LABEL[l]}</option>)}
              </select>
            </Field>
            <Field label="Corners">
              <select value={spec.radius} onChange={(e) => set("radius", e.target.value as BrandSpec["radius"])} className={selCls}>
                {RADII.map((r) => <option key={r} value={r}>{RADIUS_LABEL[r]}</option>)}
              </select>
            </Field>
            <Field label="Logo">
              <select value={spec.logo_placement} onChange={(e) => set("logo_placement", e.target.value as BrandSpec["logo_placement"])} className={selCls}>
                {LOGO_PLACEMENTS.map((l) => <option key={l} value={l}>{LOGO_LABEL[l]}</option>)}
              </select>
            </Field>
            <Field label="Background">
              <select value={spec.background_treatment} onChange={(e) => set("background_treatment", e.target.value as BrandSpec["background_treatment"])} className={selCls}>
                {BACKGROUND_TREATMENTS.map((b) => <option key={b} value={b}>{BG_LABEL[b]}</option>)}
              </select>
            </Field>
          </div>
          <div className="flex items-center gap-3">
            <button onClick={onSave} disabled={busy}
              className="rounded-xl px-4 py-2 text-[14px] font-semibold disabled:opacity-50"
              style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>Save</button>
            <button onClick={onReset} disabled={busy} className="text-[13px] text-ink-2 underline">Reset to studio defaults</button>
          </div>
        </section>
      )}
    </div>
  );
}

const selCls = "mt-1 rounded border border-line-2 bg-surface px-2 py-1.5 text-[13px] text-ink";
function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return <label className="block text-[11px] text-ink-3">{label}<br />{children}</label>;
}

/** A client-rendered sample post from the spec + a fixed sample timetable. */
function SamplePost({
  spec, variant, studioName, logoUrl,
}: { spec: BrandSpec; variant: "square-day" | "square-week" | "story-day"; studioName: string; logoUrl: string | null }) {
  const story = variant === "story-day";
  const W = story ? 220 : 280;
  const H = story ? 391 : 280;
  const radius = spec.radius === "large" ? 20 : 8;
  const c = spec.colors;
  const full = spec.background_treatment === "full";
  const bg = full ? c.accent : c.background;
  const fg = full ? c.surface : c.ink;
  const cardBg = full ? "rgba(255,255,255,0.12)" : c.surface;
  const label = variant === "square-week" ? "This week" : "Today";
  const dateText = variant === "square-week" ? SAMPLE_WEEK.range : SAMPLE_DAY.date;

  const logo = logoUrl
    ? <img src={logoUrl} alt="" style={{ height: 22, width: "auto", objectFit: "contain" }} />
    : <div style={{ fontFamily: `'${spec.display_font}'`, fontWeight: 700, fontSize: 15, color: fg }}>{studioName}</div>;

  const logoRow = (
    <div style={{
      display: "flex", marginBottom: 10,
      justifyContent: spec.logo_placement === "top-centre" ? "center" : "flex-start",
    }}>{logo}</div>
  );

  return (
    <figure className="m-0">
      <div style={{
        width: W, height: H, background: bg, color: fg, borderRadius: radius,
        padding: story ? 18 : 16, overflow: "hidden", boxShadow: "0 1px 3px rgba(0,0,0,.12)",
        border: "1px solid var(--line)", display: "flex", flexDirection: "column",
        position: "relative",
      }}>
        {spec.background_treatment === "soft" && (
          <div style={{ position: "absolute", inset: 0, background: `linear-gradient(160deg, ${c.accent}22, transparent 70%)`, pointerEvents: "none" }} />
        )}
        {spec.logo_placement !== "bottom" && logoRow}
        <div style={{ fontFamily: `'${spec.display_font}'`, fontWeight: 700, fontSize: story ? 24 : 20, lineHeight: 1.1 }}>{label}</div>
        <div style={{ fontFamily: `'${spec.body_font}'`, fontSize: 12, color: full ? c.surface : c.secondary, marginBottom: 10 }}>{dateText}</div>

        <div style={{ flex: 1, display: variant === "square-week" ? "block" : "flex", flexDirection: "column", gap: story ? 10 : 6 }}>
          {variant === "square-week"
            ? SAMPLE_WEEK.days.map((d) => (
                <div key={d.day} style={{ marginBottom: 6 }}>
                  <div style={{ fontFamily: `'${spec.display_font}'`, fontWeight: 700, fontSize: 12, color: c.accent }}>{d.day}</div>
                  {d.items.map((it, i) => (
                    <div key={i} style={{ fontFamily: `'${spec.body_font}'`, fontSize: 11, color: fg }}>{it}</div>
                  ))}
                </div>
              ))
            : SAMPLE_DAY.classes.map((cl, i) => (
                <div key={i} style={{
                  background: cardBg, borderRadius: Math.max(4, radius - 4),
                  padding: story ? "10px 12px" : "7px 10px",
                }}>
                  <div style={{ fontFamily: `'${spec.body_font}'`, fontSize: story ? 15 : 13, fontWeight: 700, color: c.accent }}>{cl.time}</div>
                  <div style={{ fontFamily: `'${spec.display_font}'`, fontSize: story ? 17 : 14, color: fg }}>{cl.name}</div>
                  <div style={{ fontFamily: `'${spec.body_font}'`, fontSize: 11, color: full ? c.surface : c.secondary }}>{cl.coach}</div>
                </div>
              ))}
        </div>

        {spec.logo_placement === "bottom"
          ? <div style={{ marginTop: 10 }}>{logo}</div>
          : <div style={{ fontFamily: `'${spec.body_font}'`, fontSize: 11, color: full ? c.surface : c.secondary, marginTop: 8 }}>Book on the app</div>}
      </div>
      <figcaption className="mt-1 text-center text-[11px] text-ink-3">
        {story ? "Story · day" : variant === "square-week" ? "Square · week" : "Square · day"}
      </figcaption>
    </figure>
  );
}
