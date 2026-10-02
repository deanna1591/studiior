import QRCode from "qrcode";
import { headers } from "next/headers";
import { notFound } from "next/navigation";
import { anonStudio } from "@/lib/anon-studio";
import { currentMemberOrigin } from "@/lib/tenant";
import { installWelcome } from "@/lib/pwa";
import { themeVars, accentRamp, neutralAccent, PRESETS, type PresetKey } from "@/lib/theme";
import InstallActions from "@/components/member/install-actions";

/**
 * Decision 51 — the public Install page, for a website's "Download the app"
 * button. No login: it resolves the studio through the anon lookup like the
 * login screen. Logo, name, the studio's welcome line, a server-generated QR of
 * this page's own URL (so a desktop visitor can point their phone at it), and
 * platform steps (iPhone Safari / Android Chrome) ordered by the visitor's
 * user agent. The word "Studiior" does not appear.
 */
export default async function InstallView({ which }: { which: "member" | "instructor" }) {
  const studio = await anonStudio();
  if (!studio?.name) notFound();

  const preset = (studio.theme_preset ?? "warm") as PresetKey;
  const accent = studio.accent_color ?? neutralAccent(preset);
  const vars = themeVars(preset, accent) as React.CSSProperties;
  const ramp = accentRamp(accent, preset);

  const origin = currentMemberOrigin() ?? "";
  const path = which === "instructor" ? "/instructor/install" : "/install";
  const appPath = which === "instructor" ? "/instructor" : "/";
  const pageUrl = `${origin}${path}`;
  const appUrl = `${origin}${appPath}`;

  const appLabel = which === "instructor" ? `${studio.name} — Instructors` : studio.name;
  const welcome = which === "instructor"
    ? `Add ${appLabel} to your home screen for one-tap access.`
    : installWelcome(studio.name, studio.install_welcome);

  // Server-rendered QR — the `qrcode` dependency, no third-party service.
  const qrSvg = await QRCode.toString(pageUrl, {
    type: "svg", margin: 1, errorCorrectionLevel: "M",
    color: { dark: "#1A1512", light: "#FFFFFF" },
  });

  const ua = (headers().get("user-agent") ?? "").toLowerCase();
  const isIOS = /iphone|ipad|ipod/.test(ua);
  const isAndroid = /android/.test(ua);
  // iPhone first on iOS, Android first on Android, iPhone first otherwise.
  const iosFirst = !isAndroid;

  const Ios = (
    <section className="m-card p-4">
      <h2 className="m-head text-[15px] text-ink">On iPhone (Safari)</h2>
      <ol className="m-sub mt-2 space-y-1.5 text-ink-2">
        <li>1. Tap the Share button (the square with an arrow).</li>
        <li>2. Scroll down and tap <span className="text-ink">Add to Home Screen</span>.</li>
        <li>3. Tap <span className="text-ink">Add</span>.</li>
      </ol>
    </section>
  );
  const Android = (
    <section className="m-card p-4">
      <h2 className="m-head text-[15px] text-ink">On Android (Chrome)</h2>
      <ol className="m-sub mt-2 space-y-1.5 text-ink-2">
        <li>1. Tap <span className="text-ink">Install</span> when the button appears below.</li>
        <li>2. Otherwise tap the ⋮ menu, then <span className="text-ink">Add to Home screen</span>.</li>
        <li>3. Confirm <span className="text-ink">Install</span>.</li>
      </ol>
    </section>
  );

  return (
    <div style={vars} className="min-h-dvh bg-paper">
      <div className="mx-auto flex max-w-lg flex-col items-center px-4 py-10 text-center">
        <span className="flex h-20 w-20 items-center justify-center rounded-3xl bg-white p-3 shadow-[0_8px_28px_rgb(0_0_0_/_0.18)]">
          {studio.logo_url ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={studio.logo_url} alt="" className="h-full w-full object-contain" />
          ) : (
            <span className="text-[34px] font-semibold leading-none" style={{ color: ramp.text }}>
              {studio.name.slice(0, 1)}
            </span>
          )}
        </span>
        <h1 className="m-title mt-4 text-ink">{appLabel}</h1>
        <p className="m-body mt-2 max-w-[34ch] text-ink-2">{welcome}</p>

        {/* The QR of this very page, for a desktop visitor to scan with a phone. */}
        <div className="mt-6 rounded-2xl bg-white p-3 shadow-[0_2px_10px_rgb(0_0_0_/_0.08)]">
          <div className="h-40 w-40 [&>svg]:h-full [&>svg]:w-full"
               aria-label="QR code to this page"
               dangerouslySetInnerHTML={{ __html: qrSvg }} />
        </div>
        <p className="m-micro mt-2 text-ink-3">Scan to open this page on your phone.</p>

        <div className="mt-6 w-full space-y-3 text-left">
          {iosFirst ? <>{Ios}{Android}</> : <>{Android}{Ios}</>}
        </div>

        <div className="w-full">
          <InstallActions appUrl={appUrl} accentFill={ramp.fill} accentOnSolid={ramp.onSolid} />
        </div>
      </div>
    </div>
  );
}
