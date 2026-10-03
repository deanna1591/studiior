import QRCode from "qrcode";
import { headers } from "next/headers";
import { notFound } from "next/navigation";
import { anonStudio } from "@/lib/anon-studio";
import { currentMemberOrigin } from "@/lib/tenant";
import { installWelcome } from "@/lib/pwa";
import { themeVars, accentRamp, neutralAccent, type PresetKey } from "@/lib/theme";
import InstallActions from "@/components/member/install-actions";

/**
 * Decision 51 + Decision 54 — the public Install page, for a website's
 * "Download the app" button. No login: it resolves the studio through the anon
 * lookup like the login screen. The word "Studiior" never appears.
 *
 * Decision 54 tightening:
 *  - the QR shows ONLY on a desktop (a phone visitor is already on their phone);
 *  - a phone sees ONLY its own platform's steps, the other folded away;
 *  - steps are large, one per line, with the real icons drawn inline as SVG;
 *  - an in-app-browser warning (Instagram/Facebook open a webview that cannot
 *    add to the home screen);
 *  - the Install button shows only on Android, where beforeinstallprompt fires.
 */

// --- inline icons (drawn, never an emoji) -----------------------------------
const ic = "inline-block h-[1.15em] w-[1.15em] shrink-0 align-[-0.2em]";
function ShareIcon() { // iOS Safari share — square with an up arrow
  return (
    <svg viewBox="0 0 24 24" fill="none" className={ic} aria-hidden stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 3v12M12 3l-4 4M12 3l4 4" />
      <path d="M6 11v8a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1v-8" />
    </svg>
  );
}
function AddSquareIcon() { // Add to Home Screen — plus in a rounded square
  return (
    <svg viewBox="0 0 24 24" fill="none" className={ic} aria-hidden stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      <rect x="3.5" y="3.5" width="17" height="17" rx="4" />
      <path d="M12 8v8M8 12h8" />
    </svg>
  );
}
function DotsVertIcon() { // Chrome ⋮
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" className={ic} aria-hidden>
      <circle cx="12" cy="5" r="1.7" /><circle cx="12" cy="12" r="1.7" /><circle cx="12" cy="19" r="1.7" />
    </svg>
  );
}
function DotsHorizIcon() { // in-app browser ⋯
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" className={ic} aria-hidden>
      <circle cx="5" cy="12" r="1.7" /><circle cx="12" cy="12" r="1.7" /><circle cx="19" cy="12" r="1.7" />
    </svg>
  );
}

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

  const ua = (headers().get("user-agent") ?? "").toLowerCase();
  const isIOS = /iphone|ipad|ipod/.test(ua);
  const isAndroid = /android/.test(ua);
  const isDesktop = !isIOS && !isAndroid;
  // An in-app webview (Instagram / Facebook / Messenger) cannot add to the home
  // screen — they need to open the real browser first.
  const inApp = /instagram|fban|fbav|fb_iab|line\/|messenger/.test(ua);

  // The QR is for a DESKTOP visitor to scan with a phone — never shown on a phone.
  const qrSvg = isDesktop
    ? await QRCode.toString(pageUrl, {
        type: "svg", margin: 1, errorCorrectionLevel: "M",
        color: { dark: "#1A1512", light: "#FFFFFF" },
      })
    : null;

  const step = "flex items-start gap-2.5 text-[15px] leading-6 text-ink";
  const Ios = (
    <section className="m-card p-4">
      <h2 className="m-head text-[15px] text-ink">On iPhone (Safari)</h2>
      <ol className="mt-3 space-y-3">
        <li className={step}><span className="num shrink-0 text-ink-3">1.</span><span className="flex-1">Tap <ShareIcon /> at the bottom of Safari.</span></li>
        <li className={step}><span className="num shrink-0 text-ink-3">2.</span><span className="flex-1">Scroll and tap <AddSquareIcon /> <span className="font-medium">Add to Home Screen</span>.</span></li>
        <li className={step}><span className="num shrink-0 text-ink-3">3.</span><span className="flex-1">Tap <span className="font-medium">Add</span> (top right).</span></li>
        <li className={step}><span className="num shrink-0 text-ink-3">4.</span><span className="flex-1">Open {appLabel} from your home screen.</span></li>
      </ol>
    </section>
  );
  const Android = (
    <section className="m-card p-4">
      <h2 className="m-head text-[15px] text-ink">On Android (Chrome)</h2>
      <ol className="mt-3 space-y-3">
        <li className={step}><span className="num shrink-0 text-ink-3">1.</span><span className="flex-1">Tap <span className="font-medium">Install</span> below (when offered), or <DotsVertIcon /> at the top right of Chrome.</span></li>
        <li className={step}><span className="num shrink-0 text-ink-3">2.</span><span className="flex-1">Tap <span className="font-medium">Add to Home screen</span>.</span></li>
        <li className={step}><span className="num shrink-0 text-ink-3">3.</span><span className="flex-1">Tap <span className="font-medium">Install</span> / <span className="font-medium">Add</span>.</span></li>
        <li className={step}><span className="num shrink-0 text-ink-3">4.</span><span className="flex-1">Open it from your home screen.</span></li>
      </ol>
    </section>
  );

  const other = (label: string, node: React.ReactNode) => (
    <details className="m-card px-4 py-3">
      <summary className="cursor-pointer text-[14px] font-medium text-ink-2">{label}</summary>
      <div className="mt-3">{node}</div>
    </details>
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

        {/* Desktop only: the QR of this page, for the visitor to scan with a phone. */}
        {qrSvg && (
          <>
            <div className="mt-6 rounded-2xl bg-white p-3 shadow-[0_2px_10px_rgb(0_0_0_/_0.08)]">
              <div className="h-40 w-40 [&>svg]:h-full [&>svg]:w-full"
                   aria-label="QR code to this page"
                   dangerouslySetInnerHTML={{ __html: qrSvg }} />
            </div>
            <p className="m-micro mt-2 text-ink-3">Scan to open this page on your phone.</p>
          </>
        )}

        {/* An in-app webview can't install — tell them how to escape it. */}
        {(inApp || !isDesktop) && (
          <p className="mt-5 w-full rounded-xl px-3 py-2.5 text-left text-[13px] leading-[19px] text-ink"
             style={{ background: "var(--coral-tint)" }}>
            If you opened this in Instagram or Facebook, tap <DotsHorizIcon /> and
            {" "}<span className="font-medium">&lsquo;Open in browser&rsquo;</span> first.
          </p>
        )}

        {/* The viewer's own platform's steps; the other folded away. Desktop
            shows both since they'll finish on a phone. */}
        <div className="mt-6 w-full space-y-3 text-left">
          {isIOS && <>{Ios}{other("Using an Android phone?", Android)}</>}
          {isAndroid && <>{Android}{other("Using an iPhone?", Ios)}</>}
          {isDesktop && <>{Ios}{Android}</>}
        </div>

        {/* The native Install prompt: only on Android where beforeinstallprompt fires. */}
        <div className="w-full">
          <InstallActions appUrl={appUrl} android={isAndroid}
                          accentFill={ramp.fill} accentOnSolid={ramp.onSolid} />
        </div>
      </div>
    </div>
  );
}
