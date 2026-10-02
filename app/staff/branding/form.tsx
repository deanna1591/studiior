"use client";

import FocalPicker from "@/components/focal-picker";
import { PHONE_LOGIN } from "@/lib/focal";
import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { PRESETS, PRESET_KEYS, accentRamp, themeVars, type PresetKey } from "@/lib/theme";
import { loginTagline as taglineText, installWelcome as welcomeText } from "@/lib/pwa";
import { Notice, buttonClass, inputClass } from "@/components/ui";
import { saveBranding, uploadLogo, uploadLoginImage, saveLoginFocus, type BrandingState } from "./actions";
import Preview from "./preview";

function Submit({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Saving…" : label}</button>;
}

/** A small sign-in sheet — the studio name over its tagline, on the accent — so
 *  the tagline is previewed where members actually read it. */
function LoginSheetPreview({ preset, accent, studioName, logoUrl, tagline }: {
  preset: PresetKey; accent: string; studioName: string; logoUrl: string | null; tagline: string;
}) {
  const vars = themeVars(preset, accent) as React.CSSProperties;
  const ramp = accentRamp(accent, preset);
  const [from, to] = [ramp.fill, ramp.fill];
  return (
    <div style={vars} className="overflow-hidden rounded-xl border border-line">
      <div className="flex flex-col items-center px-5 py-6 text-center"
           style={{ background: `linear-gradient(160deg, ${from}, ${to})` }}>
        <span className="flex h-14 w-14 items-center justify-center rounded-2xl bg-white p-2 shadow">
          {logoUrl ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={logoUrl} alt="" className="h-full w-full object-contain" />
          ) : (
            <span className="text-[24px] font-semibold leading-none" style={{ color: ramp.text }}>
              {studioName.slice(0, 1)}
            </span>
          )}
        </span>
        <p className="mt-3 text-[16px] font-semibold leading-5" style={{ color: ramp.onSolid }}>
          {studioName}
        </p>
        <p className="mt-1 text-[12.5px] leading-4" style={{ color: ramp.onSolid }}>
          {tagline}
        </p>
      </div>
    </div>
  );
}

export default function BrandingForm({
  studioName, preset: initialPreset, accent: initialAccent, logoUrl, loginImageUrl,
  loginFocusX, loginFocusY,
  contactEmail, contactPhone, loginTagline: initialTagline, installWelcome: initialWelcome,
}: {
  studioName: string;
  preset: PresetKey; accent: string | null; logoUrl: string | null;
  loginImageUrl: string | null;
  loginFocusX: number;
  loginFocusY: number;
  contactEmail: string;
  contactPhone: string;
  loginTagline: string;
  installWelcome: string;
}) {
  // Local state so the preview moves as they choose, before anything is saved.
  const [preset, setPreset] = useState<PresetKey>(initialPreset);
  const [accent, setAccent] = useState(initialAccent ?? "#BEF738");
  const [tagline, setTagline] = useState(initialTagline);
  const [welcome, setWelcome] = useState(initialWelcome);

  const [state, action] = useFormState<BrandingState, FormData>(saveBranding, null);
  const [logoState, logoAction] = useFormState<BrandingState, FormData>(uploadLogo, null);
  const [imgState, imgAction] = useFormState<BrandingState, FormData>(uploadLoginImage, null);
  const [focusState, focusAction] = useFormState<BrandingState, FormData>(saveLoginFocus, null);

  return (
    <div className="flex flex-col gap-8 lg:flex-row">
      <div className="min-w-0 flex-1 space-y-8">
        <form action={action} className="space-y-5">
          {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

          <fieldset>
            <legend className="mb-2 text-[13px] font-medium leading-[18px] text-ink">
              The look
            </legend>
            <div className="space-y-2">
              {PRESET_KEYS.map((k) => (
                <label key={k}
                       className="flex cursor-pointer gap-3 rounded border border-line bg-surface p-3 hover:bg-paper">
                  <input type="radio" name="theme_preset" value={k} className="mt-1 shrink-0"
                         checked={preset === k} onChange={() => setPreset(k)} />
                  <span className="min-w-0">
                    <span className="flex items-center gap-2">
                      <span className="text-[13px] font-medium text-ink">{PRESETS[k].label}</span>
                      <span className="flex gap-0.5">
                        {[PRESETS[k].paper, PRESETS[k].surface, PRESETS[k].ink].map((c) => (
                          <span key={c} className="inline-block h-3 w-3 rounded-sm border border-line-2"
                                style={{ background: c }} />
                        ))}
                      </span>
                    </span>
                    <span className="mt-0.5 block text-[12px] leading-4 text-ink-3">
                      {PRESETS[k].blurb}
                    </span>
                  </span>
                </label>
              ))}
            </div>
          </fieldset>

          <label className="block">
            <span className="mb-1.5 block text-[13px] font-medium leading-[18px] text-ink">
              Your accent
            </span>
            <span className="flex items-center gap-2">
              <input type="color" value={/^#[0-9a-fA-F]{6}$/.test(accent) ? accent : "#BEF738"}
                     onChange={(e) => setAccent(e.target.value.toUpperCase())}
                     className="h-9 w-14 shrink-0 rounded border border-line-2" aria-label="Accent colour" />
              <input name="accent_color" value={accent}
                     onChange={(e) => setAccent(e.target.value.toUpperCase())}
                     className={`${inputClass} font-mono uppercase`} placeholder="#BEF738" />
            </span>
            <span className="mt-1 block text-[12px] leading-4 text-ink-3">
              One colour. We work out a readable version of it for text — you do
              not have to pick two, and you cannot pick one that fails.
            </span>
          </label>

          {/* Decision 51: the sign-in sub-line and the Install-page welcome,
              with a live preview of the login sheet so the tagline is seen in
              place. Blank = the default sentence (shown as the placeholder). */}
          <fieldset className="space-y-3 border-t border-line pt-5">
            <legend className="text-[13px] font-medium leading-[18px] text-ink">
              Sign-in and install text
            </legend>
            <label className="block">
              <span className="mb-1.5 block text-[13px] leading-[18px] text-ink-2">
                Sign-in tagline
              </span>
              <input name="login_tagline" value={tagline} maxLength={140}
                     onChange={(e) => setTagline(e.target.value)}
                     className={inputClass} placeholder={taglineText(null)} />
            </label>
            <label className="block">
              <span className="mb-1.5 block text-[13px] leading-[18px] text-ink-2">
                Install welcome
              </span>
              <input name="install_welcome" value={welcome} maxLength={160}
                     onChange={(e) => setWelcome(e.target.value)}
                     className={inputClass} placeholder={welcomeText(studioName, null)} />
              <span className="mt-1 block text-[12px] leading-4 text-ink-3">
                Shown on your Install page, where members add the app to their home screen.
              </span>
            </label>
            <LoginSheetPreview preset={preset} accent={accent} studioName={studioName}
                               logoUrl={logoUrl} tagline={taglineText(tagline)} />
          </fieldset>

          <fieldset className="space-y-3 border-t border-line pt-5">
            <legend className="sr-only">Contact details</legend>
            <span className="block text-[13px] font-medium leading-[18px] text-ink">
              How members reach you
            </span>
            <span className="block text-[12px] leading-4 text-ink-3">
              This goes in the footer of every email, and a member who hits reply
              writes here. Leave it blank and replies go nowhere.
            </span>
            <label className="block">
              <span className="mb-1.5 block text-[13px] leading-[18px] text-ink-2">Email</span>
              <input name="contact_email" type="email" defaultValue={contactEmail}
                     className={inputClass} placeholder="hello@yourstudio.com" />
            </label>
            <label className="block">
              <span className="mb-1.5 block text-[13px] leading-[18px] text-ink-2">Phone</span>
              <input name="contact_phone" defaultValue={contactPhone}
                     className={inputClass} placeholder="020 7946 0102" />
            </label>
          </fieldset>

          <Submit label="Save" />
        </form>

        <form action={logoAction} className="space-y-3 border-t border-line pt-6">
          {logoState && <Notice kind={logoState.ok ? "ok" : "error"}>{logoState.message}</Notice>}
          <span className="block text-[13px] font-medium leading-[18px] text-ink">Logo</span>
          {logoUrl && (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={logoUrl} alt="Current logo"
                 className="h-12 w-12 rounded border border-line object-cover" />
          )}
          <input name="logo" type="file" accept="image/png,image/jpeg,image/webp,image/svg+xml"
                 className="block w-full text-[13px] file:mr-3 file:rounded file:border-0 file:bg-ink file:px-3 file:py-1.5 file:text-[13px] file:text-paper" />
          <p className="text-[12px] leading-4 text-ink-3">
            Square works best — it sits at 28px in the app header. Under 2 MB.
          </p>
          <Submit label="Upload" />
        </form>

        {/* ITS OWN FORM, not part of the upload. A studio that already has a
            photograph has to be able to move the point on it without finding
            the file again — and forms cannot nest. */}
        {loginImageUrl && (
          <form action={focusAction} className="space-y-3 border-t border-line pt-6">
            {focusState && <Notice kind={focusState.ok ? "ok" : "error"}>{focusState.message}</Notice>}
            <span className="block text-[13px] font-medium leading-[18px] text-ink">
              What stays in frame
            </span>
            {/* PREVIEWED AT PHONE PROPORTIONS, not in a wide band. The old
                preview was 28px tall and full width — landscape, which is the
                one shape that always looks fine, and the reason a crop keeping
                a sixth of the picture went unnoticed for as long as it did. */}
            <FocalPicker
              src={loginImageUrl}
              nameX="login_image_focus_x" nameY="login_image_focus_y"
              x={loginFocusX} y={loginFocusY}
              ratio={PHONE_LOGIN}
              label="How it crops on a phone"
              note="The sign-in screen is full bleed, so on a portrait phone only a narrow strip of a wide photograph survives."
            />
            <Submit label="Save crop" />
          </form>
        )}

        <form action={imgAction} className="space-y-3 border-t border-line pt-6">
          {imgState && <Notice kind={imgState.ok ? "ok" : "error"}>{imgState.message}</Notice>}
          <span className="block text-[13px] font-medium leading-[18px] text-ink">Login photo</span>
          {loginImageUrl ? (
            <p className="text-[12px] leading-4 text-ink-3">
              A photo is set. Choose what stays in frame below.
            </p>
          ) : (
            <p className="text-[12px] leading-4 text-ink-3">
              No photo yet, so members see your accent as a full-screen colour instead.
            </p>
          )}
          <input name="login_image" type="file" accept="image/png,image/jpeg,image/webp"
                 className="block w-full text-[13px] file:mr-3 file:rounded file:border-0 file:bg-ink file:px-3 file:py-1.5 file:text-[13px] file:text-paper" />
          <p className="text-[12px] leading-4 text-ink-3">
            The whole sign-in screen, so a wide shot of the studio works better
            than a portrait. Members see it before they sign in. Under 2 MB —
            around 1600px wide is usually well inside that.
          </p>
          <Submit label="Upload" />
        </form>
      </div>

      <div className="shrink-0">
        <h2 className="section-label mb-2 text-ink-2">What members see</h2>
        <Preview preset={preset} accent={accent} />
      </div>
    </div>
  );
}
