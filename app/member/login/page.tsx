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
 * A form on white is a webpage. This is the first thing a member sees of a
 * studio they already know, and it should look like the studio — so the whole
 * screen is theirs: their photograph, their logo, their accent on the button.
 *
 * Everything here is resolved before anyone is signed in, through
 * studio_by_slug() on a cookie-less anon client — the same pre-login lookup
 * migration 004 exists for, and the only function anon may execute. It has
 * carried login_image_url since migration 029 and nothing has ever read it.
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
      {/* The field behind everything: the studio's photograph, or its accent as
          a gradient. Never a stock image and never our lime — a studio that has
          not uploaded a picture gets its own colour, not somebody else's. */}
      {image ? (
        <>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={image} alt="" aria-hidden
               className="absolute inset-0 h-full w-full object-cover" />
          {/* The scrim does the contrast work. Weighted to the bottom, where
              the panel sits, so the top of the photograph stays a photograph. */}
          <div aria-hidden className="absolute inset-0"
               style={{ background: "linear-gradient(to bottom, rgb(0 0 0 / 0.28) 0%, rgb(0 0 0 / 0.46) 46%, rgb(0 0 0 / 0.78) 100%)" }} />
        </>
      ) : (
        // From the accent to the accent darkened a fifth — NOT from fill to
        // the ramp's text colour. That gradient ran light-to-dark, so nothing
        // could sit on both ends: near-black failed at the bottom and white
        // failed at the top. Both stops are now within one measured step of
        // `solid`, which is the colour `onSolid` was measured against.
        <div aria-hidden className="absolute inset-0"
             style={{ background: `linear-gradient(160deg, ${gradFrom} 0%, ${gradTo} 100%)` }} />
      )}

      <div className="relative mx-auto flex min-h-dvh max-w-lg flex-col px-5 pb-8 pt-16">
        <div className="flex flex-1 flex-col items-center justify-center text-center">
          {studio?.logo_url ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={studio.logo_url} alt={name}
                 className="h-24 w-24 rounded-2xl object-cover shadow-lg" />
          ) : (
            // Inverted against the field behind it. Accent-on-accent made the
            // square vanish into the gradient: the same colour cannot be both
            // the background and the thing in front of it.
            <span
              style={{ background: "var(--surface)", color: ramp.text }}
              className="flex h-24 w-24 items-center justify-center rounded-2xl text-[40px] font-semibold shadow-lg"
            >
              {name.slice(0, 1)}
            </span>
          )}

          <h1 className="m-title mt-5" style={{ color: image ? "#FFFFFF" : ramp.onSolid }}>
            {name}
          </h1>
          {/* Functional, not marketing. There is no tagline column on studios,
              and inventing a sentence in a studio's voice is worse than saying
              plainly what the app is for. */}
          <p className="m-body mt-2" style={{ color: image ? "rgb(255 255 255 / 0.85)" : ramp.onSolid, opacity: image ? 1 : 0.82 }}>
            Book your classes, check in, and see your plan.
          </p>
        </div>

        {/* Glass ONLY here, and only when there is a photograph under it to
            refract. Over the accent gradient this is a solid panel: blur over a
            flat field is fog with a compositor layer attached. */}
        <div className={`${image ? "m-glass" : "m-panel"} p-5`}>
          <LoginForm onImage={!!image} />

          <Link
            href="/signup"
            className={`m-action mt-3 flex w-full items-center justify-center rounded-xl border text-[16px] font-semibold ${
              image ? "border-white/45 text-white" : "border-line-2 bg-surface text-ink"
            }`}
          >
            Create an account
          </Link>
        </div>

        {process.env.NODE_ENV === "development" && (
          // Both branches sit on the accent field or a photograph, never on a
          // surface, so --ink-3 was the wrong greying here in one of them.
          <p className="m-micro mt-4 text-center"
             style={{ color: image ? "rgb(255 255 255 / 0.7)" : ramp.onSolid, opacity: 0.7 }}>
            Seed: alena.fabricated@example.com · nikola.simulated@example.com ·
            adela.nonexistent@example.com — password reform-dev-password
          </p>
        )}
      </div>
    </div>
  );
}
