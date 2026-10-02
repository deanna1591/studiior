import type { Metadata, Viewport } from "next";
import { notFound } from "next/navigation";
import { createServerClient } from "@supabase/ssr";
import { currentSlug } from "@/lib/tenant";
import { accentRamp, neutralAccent, type PresetKey } from "@/lib/theme";
import { iconVersion } from "@/lib/pwa";
import type { Database } from "@/lib/database.types";

/**
 * The member app is the studio's, including its name in the browser tab.
 *
 * The root layout titles everything "Studiior", which is right for the staff
 * app and wrong here: the tab, the bookmark and the name iOS uses when someone
 * adds this to their home screen are all places a member looks, and none of
 * them should say the name of the company that sold their studio software.
 *
 * Resolved through studio_by_slug() on a cookie-less anon client — the same
 * pre-login lookup middleware uses (migration 004), and the only function anon
 * may execute. Metadata is generated before anyone is signed in, so it cannot
 * depend on a session.
 */
export async function generateMetadata(): Promise<Metadata> {
  const slug = currentSlug();
  if (!slug) return {};

  const anon = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );
  const { data } = await anon.rpc("studio_by_slug", { p_slug: slug });
  const studio = Array.isArray(data) ? data[0] : data;
  // An unknown slug used to 404 in middleware, which paid for a studio_by_slug
  // round trip on EVERY request to answer a question this call already answers.
  // notFound() here costs nothing extra.
  if (!studio?.name) notFound();

  // Decision 51: the member app installs as the studio's own app. The icon URLs
  // carry ?v=<logo version> so a new logo busts the immutable icon cache.
  const v = iconVersion(studio.logo_url);
  return {
    title: studio.name,
    applicationName: studio.name,
    appleWebApp: { capable: true, title: studio.name, statusBarStyle: "default" },
    manifest: "/manifest.webmanifest",
    icons: {
      icon: [
        { url: `/icon/192?v=${v}`, sizes: "192x192", type: "image/png" },
        { url: `/icon/512?v=${v}`, sizes: "512x512", type: "image/png" },
      ],
      apple: [{ url: `/icon/180?v=${v}`, sizes: "180x180", type: "image/png" }],
    },
  };
}

/** Decision 51: the browser/status-bar theme is the studio's accent, resolved
 *  before login like the metadata above. */
export async function generateViewport(): Promise<Viewport> {
  const slug = currentSlug();
  if (!slug) return {};
  const anon = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );
  const { data } = await anon.rpc("studio_by_slug", { p_slug: slug });
  const studio = Array.isArray(data) ? data[0] : data;
  if (!studio) return {};
  const preset = (studio.theme_preset ?? "warm") as PresetKey;
  const accent = studio.accent_color ?? neutralAccent(preset);
  return { themeColor: accentRamp(accent, preset).fill };
}

export default function MemberLayout({
  children, modal,
}: {
  children: React.ReactNode;
  /** The @modal parallel-route slot: a class tapped from inside the app is
      intercepted into a bottom sheet here, while `children` (the page it was
      tapped from) stays mounted underneath. A direct load renders the full
      page and this slot is its `default` (null). */
  modal: React.ReactNode;
}) {
  return (
    <>
      {children}
      {modal}
    </>
  );
}
