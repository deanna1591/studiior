import { staffScreen } from "@/lib/screen";
import { AppShell, Empty } from "@/components/ui";
import type { PresetKey } from "@/lib/theme";
import BrandingForm from "./form";

export const dynamic = "force-dynamic";

export default async function Branding() {
  const screen = await staffScreen("/branding");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  // Owner only. studios_owner_brand is the enforcement — this decides what to
  // offer, and a manager who types the URL gets an explanation rather than a
  // form that will refuse them after they have filled it in.
  if (ctx.role !== "owner") {
    return (
      <AppShell {...shell} title="Member app">
        <Empty>
          How the member app looks is the owner&rsquo;s to set. You are signed in
          as {ctx.role.replace("_", " ")}.
        </Empty>
      </AppShell>
    );
  }

  const { data: studio } = await supabase
    .from("studios")
    .select("theme_preset, accent_color, logo_url, contact_email, contact_phone")
    .eq("id", ctx.studioId)
    .maybeSingle();

  return (
    <AppShell {...shell} title="Member app">
      <p className="mb-6 max-w-[54ch] text-[13px] leading-[20px] text-ink-2">
        This is what your members see on their phones. It does not change
        anything in here — the studio side stays as it is, so support and
        screenshots always look the same.
      </p>
      <BrandingForm
        preset={(studio?.theme_preset ?? "warm") as PresetKey}
        accent={studio?.accent_color ?? null}
        logoUrl={studio?.logo_url ?? null}
        contactEmail={studio?.contact_email ?? ""}
        contactPhone={studio?.contact_phone ?? ""}
      />
    </AppShell>
  );
}
