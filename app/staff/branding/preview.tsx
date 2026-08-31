"use client";

import { PRESETS, accentRamp, themeVars, isHex, type PresetKey } from "@/lib/theme";

/**
 * A real member Home, in the chosen preset and accent.
 *
 * Rendered with the same themeVars() the member app uses, so this is not an
 * impression of the result — it is the result, at phone width. A row of
 * swatches would let a studio approve a combination nobody had actually seen.
 */
export default function Preview({ preset, accent }: { preset: PresetKey; accent: string }) {
  const vars = themeVars(preset, accent) as React.CSSProperties;
  const ramp = accentRamp(accent, preset);
  const p = PRESETS[preset];

  return (
    <div>
      <div
        style={{ ...vars, background: p.paper }}
        className="w-[300px] overflow-hidden rounded-xl border border-line"
      >
        <div className="flex items-center gap-2 border-b px-3 py-2.5"
             style={{ borderColor: p.line, background: p.surface }}>
          <span className="flex h-6 w-6 items-center justify-center rounded text-[12px] font-semibold"
                style={{ background: ramp.fill, color: p.ink }}>R</span>
          <span className="text-[13px] font-medium" style={{ color: p.ink }}>Reform Collective</span>
        </div>

        <div className="p-3">
          <div className="rounded-lg border p-3" style={{ borderColor: p.line, background: p.surface }}>
            <p className="text-[11px]" style={{ color: p.ink3 }}>Tomorrow · 09:30</p>
            <p className="mt-1 text-[19px] font-semibold uppercase leading-6" style={{ color: p.ink }}>
              Reformer Flow
            </p>
            <p className="mt-1 text-[12px]" style={{ color: p.ink2 }}>Cleo Sampleton · Studio A</p>
            <button className="mt-3 h-11 w-full rounded-lg text-[14px] font-medium"
                    style={{ background: ramp.fill, color: p.ink }}>
              Check in
            </button>
          </div>

          <div className="mt-2 grid grid-cols-2 gap-2">
            {[["Classes left", "8"], ["Weekly streak", "11"]].map(([k, v]) => (
              <div key={k} className="rounded-lg border p-2.5" style={{ borderColor: p.line, background: p.surface }}>
                <p className="text-[10px]" style={{ color: p.ink3 }}>{k}</p>
                <p className="text-[20px] leading-6" style={{ color: p.ink }}>{v}</p>
              </div>
            ))}
          </div>

          <p className="mt-2 rounded-lg px-2.5 py-2 text-[12px]"
             style={{ background: ramp.tint, color: p.ink }}>
            A place has opened in Barre.{" "}
            <span style={{ color: ramp.text, textDecoration: "underline" }}>Take it</span>
          </p>
        </div>
      </div>

      {/* What the accent actually resolved to, said plainly. */}
      <dl className="mt-3 w-[300px] space-y-1 text-[12px] leading-4 text-ink-2">
        <div className="flex justify-between gap-3">
          <dt>Fills</dt>
          <dd className="flex items-center gap-1.5">
            <span className="inline-block h-3 w-3 rounded-sm border border-line-2"
                  style={{ background: ramp.fill }} />
            <span className="num">{ramp.fill}</span>
          </dd>
        </div>
        <div className="flex justify-between gap-3">
          <dt>Links and small text</dt>
          <dd className="flex items-center gap-1.5">
            <span className="inline-block h-3 w-3 rounded-sm border border-line-2"
                  style={{ background: ramp.text }} />
            <span className="num">{ramp.text}</span>
            <span className="num text-ink-3">{ramp.textContrast.toFixed(2)}:1</span>
          </dd>
        </div>
      </dl>

      {!isHex(accent) ? (
        <p className="mt-2 w-[300px] border-l-[3px] px-2.5 py-2 text-[12px] leading-4 text-ink"
           style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}>
          That is not a six-digit hex, so the preview is showing the default.
        </p>
      ) : ramp.fellBack ? (
        <p className="mt-2 w-[300px] border-l-[3px] px-2.5 py-2 text-[12px] leading-4 text-ink"
           style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}>
          This colour is too pale to make readable text on the {PRESETS[preset].label.toLowerCase()}{" "}
          surface, even darkened. It will still fill buttons — the preview above
          is exactly what members get — but links and small text use ink instead.
        </p>
      ) : null}
    </div>
  );
}
