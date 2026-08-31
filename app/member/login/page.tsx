import Link from "next/link";
import { createServerClient } from "@supabase/ssr";
import { currentSlug } from "@/lib/tenant";
import { themeVars, accentRamp, neutralAccent, accentGradient, type PresetKey } from "@/lib/theme";
import type { Database } from "@/lib/database.types";
import LoginForm from "./form";

export const dynamic = "force-dynamic";

/**
 * The way in.
 *
 * The photograph is the screen — full bleed, edge to edge, top to bottom — and
 * the panel is a sheet anchored to the bottom edge. The first version floated a
 * white card in the middle of the field, which framed the studio's photograph
 * and turned it into decoration behind a form. A studio's picture of its own
 * room should be the thing you are looking at.
 *
 * Everything here resolves before anyone is signed in, through studio_by_slug()
 * on a cookie-less anon client — the pre-login lookup migration 004 exists for,
 * and the only function anon may execute. It has carried login_image_url since
 * migration 029; until now nothing wrote it and nothing read it.
 *
 * The word Studiior does not appear.
 */
export default async function MemberLogin() {
  const slug = currentSlug();

  const anon = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );
  const { data } = slug
    ? await anon.rpc("studio_by_slug", { p_slug: slug })
    : { data: null };
  const studio = Array.isArray(data) ? data[0] : data;

  const name = studio?.name ?? "";
  const preset = (studio?.theme_preset ?? "warm") as PresetKey;
  const accent = studio?.accent_color ?? neutralAccent(preset);
  const image = studio?.login_image_url ?? null;
  const vars = themeVars(preset, accent) as React.CSSProperties;
  const ramp = accentRamp(accent, preset);
  const [gradFrom, gradTo] = accentGradient(ramp);

  return (
    <div style={vars} className="relative min-h-dvh overflow-hidden bg-paper">
      {/* The field. Fixed and full bleed: it is the screen, not a backdrop. */}
      {image ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={image} alt="" aria-hidden
             className="absolute inset-0 h-full w-full object-cover" />
      ) : (
        <div aria-hidden className="absolute inset-0"
             style={{ background: `linear-gradient(160deg, ${gradFrom} 0%, ${gradTo} 100%)` }} />
      )}

      {/* The scrim, over a photograph only. Transparent at the top so the
          picture is still a picture, and dark by the time it reaches the sheet,
          so the panel area is a known quantity whatever the photograph does
          there. The gradient needs none of this: it is a colour we derived and
          measured, and darkening it would only move it off the studio's own. */}
      {image && (
        <div aria-hidden className="absolute inset-0"
             style={{
               background:
                 "linear-gradient(to bottom, rgb(0 0 0 / 0.06) 0%, rgb(0 0 0 / 0.30) 34%, "
                 + "rgb(0 0 0 / 0.58) 62%, rgb(0 0 0 / 0.82) 100%)",
             }} />
      )}

      <div className="relative flex min-h-dvh flex-col">
        <div className="flex flex-1 flex-col items-center justify-center px-6 pb-8 pt-16 text-center">
          {/* The logo sits on a near-white chip rather than straight on the
              photograph. Most studio logos are a raster with a white
              background, and dropping one onto a picture leaves a white
              rectangle floating there; assuming transparency is assuming a
              PNG somebody may never have made. object-contain, not cover — a
              logo that has been cropped to fill a square is a different logo. */}
          <span className="flex h-24 w-24 items-center justify-center rounded-3xl bg-white p-3 shadow-[0_8px_28px_rgb(0_0_0_/_0.28)]">
            {studio?.logo_url ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={studio.logo_url} alt={name}
                   className="h-full w-full object-contain" />
            ) : (
              <span className="text-[40px] font-semibold leading-none"
                    style={{ color: ramp.text }}>
                {name.slice(0, 1)}
              </span>
            )}
          </span>

          <h1 className={`m-title mt-5 ${image ? "m-on-photo" : ""}`}
              style={{ color: image ? "#FFFFFF" : ramp.onSolid }}>
            {name}
          </h1>
          {/* No opacity on the gradient branch. Fading onSolid to 82% composites
              it toward the accent underneath, which took terracotta-on-Warm to
              3.61 — a sentence set below the floor by a decorative flourish,
              which is the same mistake as tinting coral until it nearly passes.
              Over a photograph the scrim guarantees a dark ground, so a slight
              fade there costs nothing measurable. */}
          <p className={`m-body mt-2 ${image ? "m-on-photo" : ""}`}
             style={{ color: image ? "rgb(255 255 255 / 0.88)" : ramp.onSolid }}>
            Book your classes, check in, and see your plan.
          </p>
        </div>

        {/* Glass ONLY over a photograph — the one place with something behind it
            to refract. Over the accent gradient this is a solid sheet: blur over
            a flat field is fog with a compositor layer attached. */}
        <div className={`${image ? "m-glass" : "m-panel"} px-5 pb-8 pt-6`}>
          <LoginForm onImage={!!image} />

          <Link
            href="/signup"
            className={`m-action mt-3 flex w-full items-center justify-center rounded-xl border text-[16px] font-semibold ${
              image ? "border-white/45 text-white" : "border-line-2 bg-surface text-ink"
            }`}
          >
            Create an account
          </Link>

          {process.env.NODE_ENV === "development" && (
            <p className="m-micro mt-4 text-center"
               style={{ color: image ? "rgb(255 255 255 / 0.6)" : "var(--ink-3)" }}>
              Seed: alena.fabricated@example.com · nikola.simulated@example.com —
              password reform-dev-password
            </p>
          )}
        </div>
      </div>
    </div>
  );
}
