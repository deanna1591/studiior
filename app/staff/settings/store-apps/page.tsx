import { staffScreen } from "@/lib/screen";
import { isManagerUp } from "@/lib/auth";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import SettingsBack from "../back";
import StoreAppsForm from "./form";
import { staffMemberOrigin } from "@/lib/member-urls-server";
import { parseFingerprints, assetlinksFor, aasaFor } from "@/lib/well-known";

export const dynamic = "force-dynamic";

/**
 * Settings → Store apps (Decision 70(b): owner OR manager — the studios RLS is
 * now owner-or-manager). The four per-tenant store identifiers, and a read-only
 * status block showing the two verification URLs and whether each is served.
 */
export default async function StoreAppsSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Store apps"><Denied what="Store apps" role={ctx.role} /></AppShell>;
  }

  const { data } = await supabase.from("studios")
    .select("slug, android_package, android_sha256_fingerprints, ios_team_id, ios_bundle_id")
    .eq("id", ctx.studioId).maybeSingle();

  const origin = await staffMemberOrigin(supabase, data?.slug ?? "");
  const assetlinksOk = assetlinksFor({
    androidPackage: data?.android_package ?? null,
    fingerprints: parseFingerprints(data?.android_sha256_fingerprints ?? "").valid,
  }) != null;
  const aasaOk = aasaFor({ teamId: data?.ios_team_id ?? null, bundleId: data?.ios_bundle_id ?? null }) != null;

  const urls: { url: string; ok: boolean }[] = [
    { url: `${origin}/.well-known/assetlinks.json`, ok: assetlinksOk },
    { url: `${origin}/.well-known/apple-app-site-association`, ok: aasaOk },
  ];

  return (
    <AppShell {...shell} title="Store apps">
      <SettingsBack />
      <SectionLabel>Store apps</SectionLabel>
      <p className="mt-2 max-w-2xl text-[13px] leading-[19px] text-ink-2">
        Your member app can be published to Google Play and the App Store as your studio&rsquo;s own app.
        Enter the identifiers the stores give you — they are used to verify your app. You do not need to
        re-publish when your app changes; the store app always shows the live site.
      </p>

      <div className="mt-3">
        <StoreAppsForm
          androidPackage={data?.android_package ?? ""}
          fingerprints={data?.android_sha256_fingerprints ?? ""}
          teamId={data?.ios_team_id ?? ""}
          bundleId={data?.ios_bundle_id ?? ""}
        />
      </div>

      <div className="mt-6 max-w-2xl rounded border border-line bg-surface px-3.5 py-3">
        <p className="text-[13px] font-medium text-ink">Verification files</p>
        <p className="mt-0.5 text-[12px] leading-[18px] text-ink-3">
          These are served automatically once the matching fields above are filled in.
        </p>
        <ul className="mt-2 space-y-2">
          {urls.map((u) => (
            <li key={u.url} className="flex items-center justify-between gap-3">
              <code className="truncate text-[12px] text-ink-2">{u.url}</code>
              <span className="shrink-0 rounded-full px-2 py-0.5 text-[11px] font-medium"
                    style={u.ok
                      ? { background: "var(--accent-chip)", color: "var(--ink)" }
                      : { background: "var(--line)", color: "var(--ink-2)" }}>
                {u.ok ? "Configured" : "Not yet"}
              </span>
            </li>
          ))}
        </ul>
      </div>
    </AppShell>
  );
}
