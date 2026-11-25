import { themeVars, neutralAccent, type PresetKey } from "@/lib/theme";
import type { BuyStudio } from "@/lib/buy-plans";

/**
 * Decision 118: the public frame for /buy pages, themed to the studio. Not
 * MemberShell: its tab bar would offer somebody without an account screens that
 * all bounce to /login.
 */
export default function BuyFrame({ studio, title, children }: {
  studio: BuyStudio | null; title?: string; children: React.ReactNode;
}) {
  const preset = (studio?.theme_preset ?? "warm") as PresetKey;
  const accent = studio?.accent_color ?? neutralAccent(preset);
  const vars = themeVars(preset, accent) as React.CSSProperties;
  return (
    <div style={vars} className="m-page min-h-dvh">
      <main className="mx-auto max-w-lg px-5 pb-12 pt-8">
        <header className="mb-5 flex items-center gap-3">
          {studio?.logo_url ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={studio.logo_url} alt="" width={44} height={44}
                 className="h-11 w-11 rounded-xl object-contain" decoding="async" />
          ) : null}
          <div>
            {studio?.name && <p className="m-micro text-ink-2">{studio.name}</p>}
            {title && <h1 className="m-head text-[24px] leading-8 text-ink">{title}</h1>}
          </div>
        </header>
        {children}
      </main>
    </div>
  );
}
