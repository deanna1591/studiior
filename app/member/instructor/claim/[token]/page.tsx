import { createServerClient } from "@supabase/ssr";
import type { Database } from "@/lib/database.types";
import { themeVars, neutralAccent, type PresetKey } from "@/lib/theme";
import ClaimForm from "./form";

export const dynamic = "force-dynamic";

type Preview = {
  state: "ok" | "invalid" | "used" | "expired";
  first_name?: string; studio_name?: string; studio_slug?: string;
  accent_color?: string | null; theme_preset?: string | null;
  logo_url?: string | null; email?: string;
};

/**
 * Where an invited instructor lands. Pre-login by nature: they have no account
 * yet, which is what the whole page is for.
 *
 * A COOKIE-LESS ANON CLIENT, deliberately. Whoever follows this link is not
 * signed in and must not be treated as whoever last used the browser — and
 * instructor_invite_preview() is one of exactly two functions anon may call
 * for this flow.
 */
export default async function ClaimPage({ params }: { params: { token: string } }) {
  const anon = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );
  const { data } = await anon.rpc("instructor_invite_preview", { p_token: params.token });
  const p = (data ?? { state: "invalid" }) as Preview;

  const preset = (p.theme_preset ?? "warm") as PresetKey;
  const vars = themeVars(
    preset, p.accent_color ?? neutralAccent(preset),
  ) as React.CSSProperties;

  const bad = {
    invalid: "That link is not one we recognise. It may have been replaced by a newer one.",
    used: "That link has already been used. If this was you, just sign in.",
    expired: "That link has expired. Ask the studio to send another.",
  } as const;

  return (
    <div className="m-page min-h-screen" style={vars}>
      <main className="mx-auto max-w-lg px-4 py-10">
        {p.state !== "ok" ? (
          <div className="m-card px-4 py-6">
            <h1 className="m-head text-[22px] leading-7 text-ink">This link will not open</h1>
            <p className="m-sub mt-2 text-ink-2">{bad[p.state]}</p>
            <a href="/instructor/login"
               className="m-sub mt-3 inline-block underline underline-offset-4"
               style={{ color: "var(--accent-text)" }}>
              Go to sign in
            </a>
          </div>
        ) : (
          <>
            <h1 className="m-head text-[24px] leading-8 text-ink">
              Hello {p.first_name}
            </h1>
            <p className="m-sub mt-2 text-ink-2">
              {p.studio_name} has set up your instructor account. Choose a
              password and you are in.
            </p>
            <ClaimForm token={params.token} email={p.email ?? ""} name={p.first_name ?? ""} />
            <p className="m-sub mt-5 text-ink-3">
              This is a web page, not an app to download. Add it to your home
              screen and it opens like one.
            </p>
          </>
        )}
      </main>
    </div>
  );
}
