import type { Metadata } from "next";
import { createServerClient } from "@supabase/ssr";
import { currentSlug } from "@/lib/tenant";
import { iconVersion } from "@/lib/pwa";
import type { Database } from "@/lib/database.types";

/**
 * Decision 51 — the instructor portal installs as its OWN app, separate from
 * the member app, as "{Studio} — Instructors" with its own manifest and scope.
 * Same host, same icons; only the name, manifest and start scope differ. The
 * member layout above still wraps these pages (parallel-route slots and the
 * studio-by-slug 404 live there); this layout only overrides the PWA metadata.
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
  if (!studio?.name) return {};

  const name = `${studio.name} — Instructors`;
  const v = iconVersion(studio.logo_url);
  return {
    title: name,
    applicationName: name,
    appleWebApp: { capable: true, title: name, statusBarStyle: "default" },
    manifest: "/instructor/manifest.webmanifest",
    icons: {
      icon: [
        { url: `/icon/192?v=${v}`, sizes: "192x192", type: "image/png" },
        { url: `/icon/512?v=${v}`, sizes: "512x512", type: "image/png" },
      ],
      apple: [{ url: `/icon/180?v=${v}`, sizes: "180x180", type: "image/png" }],
    },
  };
}

export default function InstructorLayout({ children }: { children: React.ReactNode }) {
  return <>{children}</>;
}
