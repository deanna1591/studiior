// Decision 93 (d): the five v5 schedule post styles (Notes, Receipt, Day planner,
// Y2K desktop, Coach diary), drawn to docs/post-design/v5 at 1080 wide. The v5
// mockups are 540 wide, so every measure here is the mockup's doubled. Colours
// come from the Brand kit tokens (field = background, paper = surface, ink,
// accent, muted = secondary); fonts are the kit display serif and body plus the
// vendored Space Mono, Nothing You Could Do and VT323 (Y2K only). Decorations
// (checkmarks, sparkles, hearts, the bow, the class icons) are inline SVG so a
// post draws the same on every phone.
import type { CSSProperties, ReactNode } from "react";
import {
  spotsLabel, classIcon, diaryLine, bookingLine, flexReminder, tierChip, logoFallback,
  coachPhotoBox, retroDate, weekStrip, shortClass,
  type FitPage, type PostClass, type PostDay, type PostFormat, type PostMode, type PostStyle,
} from "@/lib/schedule-post";
import { mixHex, soft, type Tokens } from "@/components/staff/post-kit";

export type Deadline = { mode?: string | null; time?: string | null; hours?: number | null };

export type V5Props = {
  style: PostStyle; t: Tokens; page: FitPage; mode: PostMode; format: PostFormat;
  headline: { lead: string; accent: string }; rangeLabel: string; dateFrom: string;
  studioName: string; logoData: string | null; coachFirst: string | null; coachData: string | null;
  footer: string; showSpots: boolean; flexMin: number; weekTotal: number; deadline: Deadline;
};

// ---------------------------------------------------------------------------
// Inline SVG decorations
// ---------------------------------------------------------------------------
type Ico = { size: number; color: string; style?: CSSProperties };
const svg = (size: number, style: CSSProperties | undefined, children: ReactNode, vb = "0 0 24 24") => (
  <svg width={size} height={size} viewBox={vb} style={{ flex: "0 0 auto", display: "inline-block", verticalAlign: "middle", ...style }} aria-hidden>{children}</svg>
);
export function Sparkle({ size, color, style }: Ico) {
  return svg(size, style, <path d="M12 1.5c.7 5.6 4.9 9.8 10.5 10.5-5.6.7-9.8 4.9-10.5 10.5C11.3 16.9 7.1 12.7 1.5 12 7.1 11.3 11.3 7.1 12 1.5Z" fill={color} />);
}
function SparkleLine({ size, color, style }: Ico) {
  return svg(size, style, <path d="M12 2.5c.6 4.9 4.6 8.9 9.5 9.5-4.9.6-8.9 4.6-9.5 9.5-.6-4.9-4.6-8.9-9.5-9.5 4.9-.6 8.9-4.6 9.5-9.5Z" fill="none" stroke={color} strokeWidth={1.8} strokeLinejoin="round" />);
}
function Ring({ size, color, style }: Ico) {
  return svg(size, style, <circle cx="12" cy="12" r="7.5" fill="none" stroke={color} strokeWidth={2.4} />);
}
function Heart({ size, color, style, fill }: Ico & { fill?: boolean }) {
  return svg(size, style, <path d="M12 20.5s-7.5-4.6-9.2-9.3C1.6 7.8 3.8 4.5 7.2 4.5c2 0 3.6 1.1 4.8 2.9 1.2-1.8 2.8-2.9 4.8-2.9 3.4 0 5.6 3.3 4.4 6.7-1.7 4.7-9.2 9.3-9.2 9.3Z" fill={fill ? color : "none"} stroke={color} strokeWidth={2.2} strokeLinejoin="round" />);
}
function Check({ size, color, style }: Ico) {
  return svg(size, style, <path d="M5 12.5l4.5 4.5L19 7.5" fill="none" stroke={color} strokeWidth={3} strokeLinecap="round" strokeLinejoin="round" />);
}
function Bow({ size, color, style }: Ico) {
  return svg(size, style, <g fill={color}>
    <path d="M12 11.5C9 7 4 5.5 2.6 7.6 1.4 9.5 3 13.4 6.6 13.9 8.8 14.2 10.6 13 12 11.5Z" />
    <path d="M12 11.5c3-4.5 8-6 9.4-3.9 1.2 1.9-.4 5.8-4 6.3-2.2.3-4-.9-5.4-2.4Z" />
    <path d="M11 12.5 8.2 21l2.4-1 1.4 2 .8-8.6Z" /><path d="M13 12.5l2.8 8.5-2.4-1-1.4 2-.8-8.6Z" />
    <circle cx="12" cy="12" r="2.3" />
  </g>);
}
function Flame({ size, color, style }: Ico) {
  return svg(size, style, <path d="M12 22c-4.1 0-7-2.9-7-6.8 0-3.4 2.1-5.2 3.6-7.3.4 1.6 1.3 2.6 2.4 3C10.6 7.4 12 4.4 15 2c-.4 3.4 1 5.3 2.4 7.2 1.1 1.5 1.6 3 1.6 5C19 18.6 16.1 22 12 22Zm0-2.2c1.9 0 3.2-1.3 3.2-3.1 0-1.6-1-2.6-2.2-4.2-.6 1.4-1.5 2.1-2.5 2.4-.8.3-1.7 1.1-1.7 2.1 0 1.6 1.3 2.8 3.2 2.8Z" fill={color} />);
}
function Bolt({ size, color, style }: Ico) {
  return svg(size, style, <path d="M13.5 2 5 13.5h6L9.8 22 19 10h-6.2L13.5 2Z" fill={color} />);
}
function Leaf({ size, color, style }: Ico) {
  return svg(size, style, <g fill="none" stroke={color} strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
    <path d="M5 19C5 10.5 10 5 20 4c0 9.5-5.5 15-15 15Z" fill={color} fillOpacity={0.18} /><path d="M5 19 14 10" />
  </g>);
}
function Sun({ size, color, style }: Ico) {
  return svg(size, style, <g stroke={color} strokeWidth={2} strokeLinecap="round">
    <circle cx="12" cy="12" r="4.2" fill={color} stroke="none" />
    {[0, 45, 90, 135, 180, 225, 270, 315].map((a) => <line key={a} x1="12" y1="2.8" x2="12" y2="5.6" transform={`rotate(${a} 12 12)`} />)}
  </g>);
}
function Moon({ size, color, style }: Ico) {
  return svg(size, style, <path d="M20 14.5A8.5 8.5 0 0 1 9.5 4 8.5 8.5 0 1 0 20 14.5Z" fill={color} />);
}
function ClassIcon({ name, size, color }: { name: string; size: number; color: string }) {
  const k = classIcon(name);
  if (k === "flame") return <Flame size={size} color={color} />;
  if (k === "bolt") return <Bolt size={size} color={color} />;
  if (k === "leaf") return <Leaf size={size} color={color} />;
  if (k === "sparkle") return <Sparkle size={size} color={color} />;
  return <Sun size={size} color={color} />;
}
/** The tier mark after a class: a filled sparkle for core, a ring for flex. */
function TierMark({ c, size, color }: { c: PostClass; size: number; color: string }) {
  return c.tier === "flex" ? <Ring size={size} color={color} /> : <Sparkle size={size} color={color} />;
}

// ---------------------------------------------------------------------------
// Shared pieces: the spots pill, the logo, a class row
// ---------------------------------------------------------------------------
/** "3 spots left" / "1 spot left" soft pill, solid "Full". Nothing at all when
 *  Show spots left is unticked (the caller does not render it, so no gap). */
function Pill({ n, t, fs, upper, retro }: { n: number | undefined; t: Tokens; fs: number; upper?: boolean; retro?: boolean }) {
  const full = !(Number(n) > 0);
  const text = upper ? spotsLabel(n).toUpperCase() : spotsLabel(n);
  if (retro) {
    return <span style={{ flex: "0 0 auto", fontFamily: "'VT323', monospace", fontSize: fs, lineHeight: 1.05, padding: `0 ${Math.round(fs * 0.45)}px`, border: `3px solid ${t.ink}`, borderRadius: 999, background: full ? t.accent : "#FFFFFF", color: full ? t.onAccent : t.ink, whiteSpace: "nowrap" }}>{text}</span>;
  }
  return (
    <span style={{
      flex: "0 0 auto", fontFamily: t.mono, fontWeight: 700, fontSize: fs, lineHeight: 1.25, whiteSpace: "nowrap",
      padding: `${Math.round(fs * 0.22)}px ${Math.round(fs * 0.84)}px`, borderRadius: 999,
      background: full ? t.accent : mixHex(t.accent, "#FFFFFF", 0.87), color: full ? t.onAccent : t.accent,
    }}>{text}</span>
  );
}

/** The Brand kit logo, or the studio name in the display serif when none. */
function Mark({ logo, name, t, h, color, align = "left" }: { logo: string | null; name: string; t: Tokens; h: number; color: string; align?: "left" | "center" | "right" }) {
  const text = logoFallback(logo, name);
  if (!text && logo) return <img src={logo} alt="" style={{ height: h, width: "auto", maxWidth: h * 6, objectFit: "contain", display: "block", margin: align === "center" ? "0 auto" : undefined }} />;
  return <span style={{ display: "block", fontFamily: t.df, fontSize: Math.round(h * 0.95), lineHeight: 1, color, whiteSpace: "nowrap", textAlign: align }}>{text}</span>;
}

/** Flatten a page's days into rows; each row knows its day and whether it is the
 *  day's first (the Receipt prints the day once). */
function flatRows(days: PostDay[]) {
  const out: { day: PostDay; c: PostClass; first: boolean }[] = [];
  for (const d of days) (d.classes ?? []).forEach((c, i) => out.push({ day: d, c, first: i === 0 }));
  return out;
}
function dow3(label: string) { return (label.split(/\s+/)[0] || label).slice(0, 3); }
function dayShort(d: PostDay) {
  // "Tuesday 2 Dec" -> "TUE 2 DEC"
  const parts = d.label.split(/\s+/);
  return [parts[0]?.slice(0, 3), ...parts.slice(1)].join(" ").toUpperCase();
}
function partTag(page: FitPage) { return page.parts > 1 ? `Part ${page.part} of ${page.parts}` : null; }
const nowrap: CSSProperties = { minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" };

// ---------------------------------------------------------------------------
// 1. Notes — a phone-notes card on soft blobs, a checkmark per class
// ---------------------------------------------------------------------------
function Notes(p: V5Props) {
  const { t, page, mode, format, headline, rangeLabel, studioName, logoData, coachFirst, footer, showSpots } = p;
  const story = format === "story";
  const s = page.scale;
  const fs = Math.round((story ? 28 : 24) * s);
  const gap = Math.round((story ? 22 : 12) * s);
  const rows = flatRows(page.days);
  const lead = coachFirst ? headline.lead : headline.lead.toLowerCase();
  const tag = partTag(page);
  return (
    <div style={{ width: 1080, height: story ? 1920 : 1080, background: t.background, position: "relative", overflow: "hidden", fontFamily: t.bf, color: t.ink }}>
      <div style={{ position: "absolute", width: 840, height: 600, right: -280, top: -180, borderRadius: "50%", background: mixHex(t.background, t.surface, 0.55) }} />
      <div style={{ position: "absolute", width: 720, height: 720, left: -320, bottom: -280, borderRadius: "50%", background: mixHex(t.background, t.accent, 0.22) }} />
      <div data-post-box style={{ position: "absolute", left: 116, right: 116, top: story ? 180 : 80, bottom: story ? 180 : 80, background: t.surface, borderRadius: 68, boxShadow: `0 20px 60px ${soft(t.ink, 0.15)}`, padding: "44px 52px", overflow: "hidden" }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", color: t.accent }}>
          <Mark logo={logoData} name={studioName} t={t} h={40} color={t.ink} />
          <span style={{ display: "flex", gap: 18, alignItems: "center" }}>
            {svg(30, undefined, <g fill="none" stroke={t.accent} strokeWidth={2.2} strokeLinecap="round" strokeLinejoin="round"><path d="M12 15V3M7 8l5-5 5 5" /><path d="M5 13v7h14v-7" /></g>)}
            {svg(30, undefined, <g fill={t.accent}><circle cx="5" cy="12" r="2.2" /><circle cx="12" cy="12" r="2.2" /><circle cx="19" cy="12" r="2.2" /></g>)}
          </span>
        </div>
        <h1 style={{ fontFamily: t.df, fontWeight: 400, fontSize: story ? 104 : 80, lineHeight: 1, margin: "28px 0 8px", color: t.ink }}>
          {lead}<em style={{ fontStyle: "italic", color: t.accent }}>{headline.accent}</em>
        </h1>
        <div style={{ fontSize: story ? 26 : 22, color: t.secondary, marginBottom: 20, display: "flex", alignItems: "center", gap: 8 }}>
          <span>{rangeLabel}</span><span>·</span><Sparkle size={story ? 22 : 18} color={t.secondary} /><span>always runs</span>
          {tag && <><span>·</span><span style={{ color: t.accent }}>{tag}</span></>}
        </div>
        {rows.map(({ day, c }, i) => (
          <div key={i} style={{ display: "flex", gap: 18, alignItems: "center", margin: `${gap}px 0`, fontSize: fs, lineHeight: 1.25 }}>
            <span style={{ flex: `0 0 ${Math.round(fs * 1.4)}px`, height: Math.round(fs * 1.4), borderRadius: "50%", background: t.accent, display: "flex", alignItems: "center", justifyContent: "center" }}>
              <Check size={Math.round(fs * 0.95)} color={t.onAccent} />
            </span>
            <span style={{ flex: "1 1 auto", ...nowrap }}>
              {mode === "week" && <b style={{ fontWeight: 700 }}>{dow3(day.label)} </b>}
              <span style={{ color: t.secondary }}>{c.time}</span> {c.name}{!coachFirst && c.coach ? ` · ${c.coach}` : ""}{" "}
              <TierMark c={c} size={Math.round(fs * 0.8)} color={t.accent} />
            </span>
            {showSpots && <Pill n={c.spots_left} t={t} fs={Math.round(fs * 0.8)} />}
          </div>
        ))}
        <div style={{ position: "absolute", bottom: 36, left: 52, right: 52, display: "flex", justifyContent: "space-between", alignItems: "center", color: t.accent }}>
          {svg(34, undefined, <g fill="none" stroke={t.accent} strokeWidth={2.2} strokeLinejoin="round"><rect x="3.5" y="3.5" width="17" height="17" rx="3" /><path d="M8 12.5l3 3 5-6" strokeLinecap="round" /></g>)}
          {svg(34, undefined, <g fill="none" stroke={t.accent} strokeWidth={2.2}><circle cx="12" cy="12" r="8.5" /><circle cx="12" cy="12" r="3.5" /></g>)}
          <span style={{ fontFamily: t.hand, fontSize: 28, color: t.ink, display: "flex", alignItems: "center", gap: 10 }}>{footer.toLowerCase()} <Heart size={26} color={t.ink} /></span>
          {svg(34, undefined, <path d="M4 20l1-4.5L16 4.5l3.5 3.5L8.5 19 4 20Z" fill="none" stroke={t.accent} strokeWidth={2.2} strokeLinejoin="round" />)}
        </div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// 2. Receipt — a printer receipt coming out of a slot on a pink field
// ---------------------------------------------------------------------------
function Receipt(p: V5Props) {
  const { t, page, mode, format, rangeLabel, studioName, logoData, coachFirst, showSpots, weekTotal } = p;
  const story = format === "story";
  const s = page.scale;
  const fs = Math.round((story ? 24 : 20) * s);
  const rowGap = Math.round((story ? 14 : 5) * s);
  const dark = mixHex(t.ink, "#000000", 0.15);
  const white = "rgba(255,255,255,.6)";
  const zig = Array.from({ length: 25 }, (_, i) => `${100 - i * 4}% ${i % 2 ? "calc(100% - 28px)" : "100%"}`).join(",");
  const tag = partTag(page);
  const head = [studioName.toUpperCase(), mode === "week" ? `WEEK OF ${rangeLabel.toUpperCase()}` : rangeLabel.toUpperCase(), coachFirst ? `COACH ${coachFirst.toUpperCase()}` : null, tag?.toUpperCase()].filter(Boolean).join(" · ");
  return (
    <div style={{ width: 1080, height: story ? 1920 : 1080, background: `linear-gradient(160deg, ${mixHex(t.background, t.accent, 0.12)}, ${mixHex(t.background, t.accent, 0.32)})`, position: "relative", overflow: "hidden" }}>
      <Sparkle size={88} color={white} style={{ position: "absolute", left: 32, top: story ? 520 : 300 }} />
      <Heart size={88} color={white} style={{ position: "absolute", right: 28, top: story ? 1040 : 560 }} />
      <Bow size={112} color={mixHex(t.accent, "#E5484D", 0.35)} style={{ position: "absolute", left: 40, bottom: story ? 120 : 40 }} />
      <SparkleLine size={56} color={white} style={{ position: "absolute", right: 52, top: story ? 120 : 140 }} />
      <div style={{ position: "absolute", left: 120, right: 120, top: story ? 192 : 76, height: 44, borderRadius: 16, background: "linear-gradient(#f4f4f4,#bdbdbd)", boxShadow: "0 8px 16px rgba(0,0,0,.25)" }} />
      <div data-post-box style={{ position: "absolute", left: 160, right: 160, top: story ? 220 : 104, background: "#FFFFFF", padding: story ? "52px 48px 80px" : "36px 40px 60px", fontFamily: t.mono, fontSize: fs, color: dark, clipPath: `polygon(0 0,100% 0,100% calc(100% - 28px),${zig},0 calc(100% - 28px))` }}>
        <div style={{ textAlign: "center", marginBottom: 16 }}><Mark logo={logoData} name={studioName} t={t} h={story ? 56 : 40} color={t.ink} align="center" /></div>
        <h2 style={{ fontFamily: t.bf, fontWeight: 800, color: t.accent, fontSize: story ? 64 : 48, textAlign: "center", margin: 0, lineHeight: 1.1 }}>CLASS SCHEDULE</h2>
        <div style={{ textAlign: "center", fontSize: story ? 22 : 18, margin: "4px 0 8px" }}>{head}</div>
        <div style={{ borderTop: `4px dotted ${dark}`, margin: "10px 0" }} />
        {flatRows(page.days).map(({ day, c, first }, i) => (
          <div key={i} style={{ display: "flex", gap: 12, alignItems: "center", margin: `${rowGap}px 0` }}>
            {mode === "week" && <span style={{ flex: "0 0 56px", color: t.accent, fontWeight: 700 }}>{first ? dow3(day.label).toUpperCase() : ""}</span>}
            <span style={{ flex: "1 1 auto", ...nowrap }}>{shortClass(c.name).toUpperCase()}{!coachFirst && c.coach ? ` · ${c.coach.toUpperCase()}` : ""}</span>
            {showSpots && <Pill n={c.spots_left} t={t} fs={Math.round(fs * 0.95)} upper />}
            <span style={{ flex: "0 0 auto", minWidth: Math.round(fs * 6.2), textAlign: "right" }}>{c.time}</span>
          </div>
        ))}
        <div style={{ borderTop: `4px dotted ${dark}`, margin: "10px 0" }} />
        <div style={{ display: "flex", justifyContent: "space-between" }}><span>ITEM COUNT</span><span>{weekTotal}</span></div>
        <div style={{ height: 56, margin: "16px 0", background: `repeating-linear-gradient(90deg,${dark} 0 4px,#fff 4px 8px,${dark} 8px 10px,#fff 10px 16px,${dark} 16px 22px,#fff 22px 24px)` }} />
        <div style={{ textAlign: "center", fontSize: story ? 22 : 18, display: "flex", justifyContent: "center", alignItems: "center", gap: 8 }}>SEE YOU AT THE REFORMER <Heart size={story ? 22 : 18} color={dark} /></div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// 3. Day planner — a week strip, then the day's timeline (Day only)
// ---------------------------------------------------------------------------
function rangeText(c: PostClass) {
  if (!c.end) return c.time;
  const a = /\s*(AM|PM)$/i.exec(c.time), b = /\s*(AM|PM)$/i.exec(c.end);
  const start = a && b && a[1].toUpperCase() === b[1].toUpperCase() ? c.time.replace(/\s*(AM|PM)$/i, "") : c.time;
  return `${start} – ${c.end}`;
}
function Timeline(p: V5Props) {
  const { t, page, format, studioName, logoData, coachFirst, showSpots, flexMin, deadline, dateFrom, footer } = p;
  const story = format === "story";
  const s = page.scale;
  const day = page.days[0];
  const date = day?.date ?? dateFrom;
  const parts = (day?.label ?? "").split(/\s+/);
  const weekday = parts[0] ?? "";
  const longDate = new Date(`${date}T12:00:00Z`).toLocaleDateString("en-GB", { day: "numeric", month: "long", timeZone: "UTC" });
  const rowH = Math.round((story ? 192 : 120) * s);
  const ic = Math.round((story ? 112 : 84) * Math.max(s, 0.85));
  const tint = mixHex(t.surface, t.accent, 0.12);
  const listBg = mixHex(t.surface, "#FFFFFF", 0.7);
  const tag = partTag(page);
  const close = bookingLine(deadline ?? {}) ?? footer.toLowerCase();
  const row = (key: string | number, icon: ReactNode, top: ReactNode, name: ReactNode, right?: ReactNode) => (
    <div key={key} style={{ display: "flex", alignItems: "center", gap: 24, height: rowH, position: "relative" }}>
      <div style={{ flex: `0 0 ${ic}px`, height: ic, borderRadius: "50%", background: tint, display: "flex", alignItems: "center", justifyContent: "center", zIndex: 1 }}>{icon}</div>
      <div style={{ flex: "1 1 auto", minWidth: 0 }}>
        <div style={{ fontSize: Math.round((story ? 26 : 21) * s), lineHeight: 1.3, color: t.secondary, ...nowrap }}>{top}</div>
        <div style={{ fontSize: Math.round((story ? 42 : 32) * s), lineHeight: 1.25, fontWeight: 600, color: t.ink, ...nowrap }}>{name}</div>
      </div>
      {right}
    </div>
  );
  return (
    <div style={{ width: 1080, height: story ? 1920 : 1080, background: t.surface, position: "relative", overflow: "hidden", fontFamily: t.bf, color: t.ink }}>
      <div style={{ padding: story ? "120px 52px 20px" : "40px 52px 12px", position: "relative" }}>
        <div style={{ position: "absolute", right: 48, top: story ? 132 : 48 }}><Mark logo={logoData} name={studioName} t={t} h={story ? 48 : 32} color={t.ink} align="right" /></div>
        <h1 style={{ fontFamily: t.df, fontWeight: 400, fontSize: story ? 96 : 68, lineHeight: 1, margin: 0, paddingRight: 260 }}>
          {weekday} <em style={{ fontStyle: "italic", color: t.accent }}>{longDate}</em>
        </h1>
        {(coachFirst || tag) && <div style={{ fontSize: story ? 26 : 20, color: t.secondary, marginTop: 6 }}>{[coachFirst ? `with Coach ${coachFirst}` : null, tag].filter(Boolean).join(" · ")}</div>}
      </div>
      <div style={{ display: "flex", justifyContent: "space-between", padding: "8px 52px 20px", fontSize: story ? 24 : 22, color: t.secondary, textAlign: "center" }}>
        {weekStrip(date).map((d) => (
          <div key={d.dow}>{d.dow}
            <span style={{ display: "block", fontSize: 32, fontWeight: 700, width: 60, height: 60, lineHeight: "60px", borderRadius: "50%", margin: "6px auto 0", background: d.on ? t.ink : "transparent", color: d.on ? t.surface : t.ink }}>{d.day}</span>
          </div>
        ))}
      </div>
      <div data-post-box style={{ position: "absolute", left: 0, right: 0, bottom: 0, top: story ? 380 : (coachFirst || tag ? 270 : 240), background: listBg, borderRadius: "52px 52px 0 0", padding: story ? "48px 44px 24px" : "24px 44px" }}>
        <div style={{ position: "absolute", left: 44 + ic / 2 - 2, top: 48, bottom: 48, width: 4, background: mixHex(t.surface, t.accent, 0.15) }} />
        {(day?.classes ?? []).map((c, i) => {
          const chip = tierChip(c, flexMin);
          const cfs = Math.round((story ? 23 : 19) * s);
          return row(i, <ClassIcon name={c.name} size={Math.round(ic * 0.45)} color={t.accent} />,
            <>{rangeText(c)}{c.coach ? ` · ${c.coach}` : ""}</>, c.name,
            <div style={{ marginLeft: "auto", display: "flex", flexDirection: "column", alignItems: "flex-end", gap: 8, flex: "0 0 auto" }}>
              <span style={{ fontSize: cfs, fontWeight: 700, borderRadius: 999, padding: `${Math.round(cfs * 0.2)}px ${Math.round(cfs * 0.84)}px`, whiteSpace: "nowrap",
                ...(chip.kind === "core" ? { background: mixHex(t.accent, "#FFFFFF", 0.86), color: t.ink } : { border: `2px solid ${mixHex(t.secondary, "#FFFFFF", 0.75)}`, color: t.secondary, background: "#FFFFFF" }) }}>{chip.text}</span>
              {showSpots && <Pill n={c.spots_left} t={t} fs={cfs} />}
            </div>);
        })}
        {story && row("close", <Moon size={Math.round(ic * 0.45)} color={t.accent} />, close,
          <span style={{ fontFamily: t.hand, fontWeight: 400, display: "inline-flex", alignItems: "center", gap: 14 }}>see you there <Heart size={40} color={t.ink} /></span>)}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// 4. Y2K desktop — retro windows
// ---------------------------------------------------------------------------
function Win({ box, bg, bar, title, t, children, fs, dots }: { box: number[]; bg: string; bar: string; title: ReactNode; t: Tokens; children: ReactNode; fs: number; dots?: boolean }) {
  const [l, tp, w, h] = box;
  return (
    <div style={{ position: "absolute", left: l, top: tp, width: w, height: h, border: `5px solid ${t.ink}`, background: bg, boxShadow: `12px 12px 0 ${t.ink}`, overflow: "hidden" }}>
      <div style={{ height: 56, borderBottom: `5px solid ${t.ink}`, display: "flex", alignItems: "center", padding: "0 20px", gap: 12, fontSize: fs, background: bar, whiteSpace: "nowrap" }}>
        {dots && ["#F38D8D", "#FFF59D", "#A8E6CF"].map((c) => <span key={c} style={{ width: 22, height: 22, borderRadius: "50%", border: `4px solid ${t.ink}`, background: c, flex: "0 0 auto" }} />)}
        <span style={{ marginLeft: 6 }}>{title}</span>
      </div>
      {children}
    </div>
  );
}
function Retro(p: V5Props) {
  const { t, page, mode, format, studioName, logoData, showSpots, flexMin, deadline, footer, dateFrom } = p;
  const story = format === "story";
  const s = page.scale;
  const fs = Math.round((story ? 48 : 36) * s);
  const B = story
    ? { w: [44, 180, 992, 1040], d: [44, 1280, 460, 220], r: [552, 1280, 484, 400], n: [44, 1720, 992, 156] }
    : { w: [44, 44, 660, 700], d: [744, 44, 292, 192], r: [744, 280, 292, 464], n: [44, 788, 992, 248] };
  const tag = page.parts > 1 ? ` (${page.part}/${page.parts})` : "";
  const day0 = page.days[0];
  const title = (mode === "week" ? "THIS_WEEK.EXE" : `${(day0?.label.split(/\s+/)[0] ?? "TODAY").toUpperCase()}.EXE`) + tag;
  const flexLine = flexReminder(flexMin, deadline ?? {});
  const vt = "'VT323', monospace";
  return (
    <div style={{ width: 1080, height: story ? 1920 : 1080, background: mixHex(t.surface, t.background, 0.18), position: "relative", overflow: "hidden", fontFamily: vt, color: t.ink }}>
      <Win dots box={B.w} t={t} fs={40} title={title} bg={mixHex(t.background, t.surface, 0.55)} bar={mixHex(t.accent, t.background, 0.55)}>
        <div data-post-box style={{ padding: "12px 20px", fontSize: fs, lineHeight: story ? 1.25 : 1.1, height: B.w[3] - 66, overflow: "hidden" }}>
          {flatRows(page.days).map(({ day, c }, i) => (
            <div key={i} style={{ display: "flex", alignItems: "center", gap: 12 }}>
              <span style={{ flex: "1 1 auto", ...nowrap }}>
                {mode === "week" ? `${dow3(day.label).toUpperCase()} ` : ""}{c.time.padEnd(8, " ")} {shortClass(c.name).toUpperCase()}{" "}
                <TierMark c={c} size={Math.round(fs * 0.55)} color={t.ink} />
              </span>
              {showSpots && <Pill n={c.spots_left} t={t} fs={Math.round(fs * 0.83)} upper retro />}
            </div>
          ))}
        </div>
      </Win>
      <Win box={B.d} t={t} fs={36} title="TODAY'S DATE" bg="#FFFFFF" bar={mixHex(t.surface, t.background, 0.4)}>
        <div style={{ fontSize: story ? 80 : 56, textAlign: "center", lineHeight: 1 }}>{retroDate(day0?.date ?? dateFrom)}</div>
        <div style={{ padding: "4px 12px 0" }}><Mark logo={logoData} name={studioName} t={t} h={story ? 48 : 28} color={t.ink} align="center" /></div>
      </Win>
      <Win box={B.r} t={t} fs={40} title="REMINDERS" bg={mixHex(t.surface, "#FFF3C4", 0.6)} bar={mixHex("#F6E39B", t.background, 0.2)}>
        <div style={{ padding: "12px 20px", fontSize: story ? 42 : 34, lineHeight: 1.1 }}>
          <div><Sparkle size={story ? 26 : 22} color={t.ink} /> always runs</div>
          {flexLine && <div><Ring size={story ? 26 : 22} color={t.ink} /> {flexLine}</div>}
          <div>grip socks on <Heart size={story ? 26 : 22} color={t.ink} /></div>
          <div>{footer.toLowerCase()}</div>
        </div>
      </Win>
      <Win box={B.n} t={t} fs={40} title="NOTE 2 SELF" bg={mixHex(t.background, t.surface, 0.35)} bar={mixHex(t.background, t.accent, 0.3)}>
        {story
          ? <div style={{ padding: "12px 24px", fontSize: 44, display: "flex", alignItems: "center", gap: 14 }}>book my reformer class -&gt; done <Check size={36} color={t.ink} /></div>
          : <div style={{ padding: "20px 24px", display: "flex", gap: 24 }}>
              <div style={{ border: `5px solid ${t.ink}`, borderRadius: 20, background: "#FFFFFF", padding: "10px 20px", fontSize: 36, boxShadow: `6px 6px 0 ${t.ink}` }}>book my reformer class</div>
              <div style={{ border: `5px solid ${t.ink}`, borderRadius: 20, background: t.accent, color: t.onAccent, padding: "10px 20px", fontSize: 36, boxShadow: `6px 6px 0 ${t.ink}`, display: "flex", alignItems: "center", gap: 10 }}>done <Check size={30} color={t.onAccent} /> see u there</div>
            </div>}
      </Win>
    </div>
  );
}

// ---------------------------------------------------------------------------
// 5. Coach diary — the coach's photo and a diary page (needs a coach)
// ---------------------------------------------------------------------------
function possessive(first: string) { return /s$/i.test(first) ? `${first}'` : `${first}'s`; }
function Coach(p: V5Props) {
  const { t, page, mode, format, studioName, logoData, coachFirst, coachData, showSpots } = p;
  const story = format === "story";
  const s = page.scale;
  const box = coachPhotoBox(format);
  const fs = Math.round((story ? 30 : 23) * s);
  const hfs = Math.round((story ? 30 : 25) * s);
  const first = coachFirst ?? "";
  if (!coachFirst) {
    return <div style={{ width: 1080, height: story ? 1920 : 1080, background: t.background, display: "flex", alignItems: "center", justifyContent: "center", fontFamily: t.df, fontSize: 48, color: t.ink }}>Pick a coach</div>;
  }
  const lastDate = page.days[page.days.length - 1]?.date;
  return (
    <div style={{ width: 1080, height: story ? 1920 : 1080, background: "#FFFFFF", position: "relative", overflow: "hidden", fontFamily: t.bf, color: t.ink }}>
      <div style={{ position: "absolute", left: box.left, top: box.top, width: box.width, height: box.height, background: `linear-gradient(180deg, ${t.background}, ${mixHex(t.background, t.accent, 0.22)})`, overflow: "hidden" }}>
        {coachData && <img data-coach-photo src={coachData} alt="" style={{ width: "100%", height: "100%", objectFit: box.objectFit as CSSProperties["objectFit"], objectPosition: box.objectPosition }} />}
      </div>
      <div data-post-box style={{ position: "absolute", left: story ? 0 : 360, top: story ? 920 : 0, right: 0, bottom: 0, background: t.surface, boxShadow: `-16px 0 40px ${soft(t.ink, 0.12)}`, borderRadius: story ? "56px 56px 0 0" : 0, padding: story ? "44px 68px 0" : "44px 44px 0 52px" }}>
        <div style={{ fontFamily: t.hand, fontSize: story ? 36 : 28, color: t.accent, display: "flex", alignItems: "center", gap: 10 }}>
          {mode === "week" ? "teaching this week" : "teaching today"} <Sparkle size={story ? 28 : 22} color={t.accent} />
        </div>
        <h1 style={{ fontFamily: t.df, fontWeight: 400, fontSize: story ? 88 : 76, lineHeight: 0.95, margin: "6px 0 6px" }}>
          Coach <em style={{ fontStyle: "italic", color: t.accent }}>{possessive(first)}</em> {mode === "week" ? "week" : "day"}
        </h1>
        {page.parts > 1 && <div style={{ fontFamily: t.mono, fontSize: 18, color: t.secondary }}>{partTag(page)}</div>}
        {page.days.map((d) => (
          <div key={d.date}>
            <div style={{ fontWeight: 800, color: t.accent, fontSize: hfs, marginTop: Math.round(20 * s), display: "flex", justifyContent: "space-between", alignItems: "baseline", borderBottom: `2px solid ${mixHex(t.surface, t.accent, 0.15)}`, paddingBottom: 4, gap: 16 }}>
              <span style={{ whiteSpace: "nowrap" }}>{dayShort(d)}</span>
              <span style={{ fontFamily: t.hand, fontWeight: 400, color: t.ink, fontSize: Math.round(hfs * 0.92), ...nowrap }}>dear diary, {diaryLine(d, { isLast: page.part === page.parts && d.date === lastDate && page.days.length > 1 })}</span>
            </div>
            {d.classes.map((c, i) => (
              <div key={i} style={{ display: "flex", alignItems: "center", gap: 12, fontSize: fs, margin: `${Math.round((story ? 12 : 8) * s)}px 0 0 4px` }}>
                <span style={{ flex: "1 1 auto", ...nowrap }}>{c.time} {c.name} {c.tier !== "flex" && <Sparkle size={Math.round(fs * 0.75)} color={t.ink} />}</span>
                {showSpots && <Pill n={c.spots_left} t={t} fs={Math.round(fs * 0.82)} />}
              </div>
            ))}
          </div>
        ))}
        <div style={{ position: "absolute", bottom: story ? 52 : 36, left: story ? 68 : 52, right: 200, fontFamily: t.hand, fontSize: story ? 40 : 32, lineHeight: 1.2 }}>
          book your spot on the app<br />
          <span style={{ display: "inline-flex", alignItems: "center", gap: 12 }}>see you at the reformer! <Bow size={story ? 44 : 36} color={t.accent} /></span>
        </div>
        <div style={{ position: "absolute", right: 44, bottom: story ? 64 : 40 }}><Mark logo={logoData} name={studioName} t={t} h={story ? 52 : 32} color={t.ink} align="right" /></div>
      </div>
    </div>
  );
}

export function V5Post(p: V5Props) {
  if (p.style === "notes") return <Notes {...p} />;
  if (p.style === "receipt") return <Receipt {...p} />;
  if (p.style === "timeline") return <Timeline {...p} />;
  if (p.style === "retro") return <Retro {...p} />;
  return <Coach {...p} />;
}

/** A tiny swatch for the style picker. */
export function V5Thumb({ style, c }: { style: PostStyle; c: { background: string; surface: string; ink: string; accent: string } }) {
  const base: CSSProperties = { width: 26, height: 26, borderRadius: 5, flex: "0 0 auto", overflow: "hidden", border: `1px solid ${soft(c.ink, 0.15)}`, position: "relative" };
  if (style === "notes") return <div style={{ ...base, background: c.background }}><div style={{ position: "absolute", inset: "4px 5px", background: c.surface, borderRadius: 4 }} /></div>;
  if (style === "receipt") return <div style={{ ...base, background: mixHex(c.background, c.accent, 0.25) }}><div style={{ position: "absolute", left: 6, right: 6, top: 3, bottom: 4, background: "#fff" }} /></div>;
  if (style === "timeline") return <div style={{ ...base, background: c.surface }}><div style={{ position: "absolute", left: 4, top: 4, width: 6, height: 6, borderRadius: "50%", background: c.accent }} /><div style={{ position: "absolute", left: 4, top: 14, width: 6, height: 6, borderRadius: "50%", background: c.accent }} /><div style={{ position: "absolute", left: 13, right: 4, top: 6, height: 2, background: c.ink }} /></div>;
  if (style === "retro") return <div style={{ ...base, background: c.surface }}><div style={{ position: "absolute", inset: "4px 4px 6px 4px", border: `2px solid ${c.ink}`, boxShadow: `2px 2px 0 ${c.ink}` }} /></div>;
  return <div style={{ ...base, background: c.surface }}><div style={{ position: "absolute", left: 0, top: 0, bottom: 0, width: 9, background: c.background }} /></div>;
}
