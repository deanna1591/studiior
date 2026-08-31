"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { PRESETS, PRESET_KEYS, type PresetKey } from "@/lib/theme";
import { Notice, buttonClass, inputClass } from "@/components/ui";
import { saveBranding, uploadLogo, uploadLoginImage, type BrandingState } from "./actions";
import Preview from "./preview";

function Submit({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Saving…" : label}</button>;
}

export default function BrandingForm({
  preset: initialPreset, accent: initialAccent, logoUrl, loginImageUrl,
  contactEmail, contactPhone,
}: {
  preset: PresetKey; accent: string | null; logoUrl: string | null;
  loginImageUrl: string | null;
  contactEmail: string;
  contactPhone: string;
}) {
  // Local state so the preview moves as they choose, before anything is saved.
  const [preset, setPreset] = useState<PresetKey>(initialPreset);
  const [accent, setAccent] = useState(initialAccent ?? "#BEF738");

  const [state, action] = useFormState<BrandingState, FormData>(saveBranding, null);
  const [logoState, logoAction] = useFormState<BrandingState, FormData>(uploadLogo, null);
  const [imgState, imgAction] = useFormState<BrandingState, FormData>(uploadLoginImage, null);

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

        <form action={imgAction} className="space-y-3 border-t border-line pt-6">
          {imgState && <Notice kind={imgState.ok ? "ok" : "error"}>{imgState.message}</Notice>}
          <span className="block text-[13px] font-medium leading-[18px] text-ink">Login photo</span>
          {loginImageUrl ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={loginImageUrl} alt="Current login photo"
                 className="h-28 w-full rounded border border-line object-cover" />
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
