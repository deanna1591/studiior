import { anonStudio } from "@/lib/anon-studio";
import { themeVars, neutralAccent, type PresetKey } from "@/lib/theme";

export const dynamic = "force-dynamic";

/**
 * Decision 69 — the public "your account has been deleted" page. Reached after
 * deletion, when there is NO session, so it must not use memberScreen. Branded
 * from the anon studio lookup, like the signed-out /checkin frame.
 */
export default async function AccountDeleted() {
  const studio = await anonStudio();
  const preset = (studio?.theme_preset ?? "warm") as PresetKey;
  const accent = studio?.accent_color ?? neutralAccent(preset);
  const vars = themeVars(preset, accent) as React.CSSProperties;

  return (
    <div className="m-page min-h-screen" style={vars}>
      <main className="mx-auto flex min-h-screen max-w-lg flex-col items-center justify-center px-5 text-center">
        {studio?.logo_url ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={studio.logo_url} alt="" className="mb-5 h-16 w-16 rounded-2xl object-contain" />
        ) : null}
        <h1 className="m-head text-[22px] leading-7 text-ink">Your account has been deleted</h1>
        <p className="m-body mt-2 text-ink-2">
          {studio?.name ? `Your account at ${studio.name} has been removed.` : "Your account has been removed."}
          {" "}Thanks for being with us.
        </p>
      </main>
    </div>
  );
}
