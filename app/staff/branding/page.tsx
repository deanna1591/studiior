import { staffScreen } from "@/lib/screen";
import { isManagerUp } from "@/lib/auth";
import { AppShell, Empty } from "@/components/ui";
import type { PresetKey } from "@/lib/theme";
import BrandingForm from "./form";

export const dynamic = "force-dynamic";

export default async function Branding() {
  const screen = await staffScreen("/branding");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  // Decision 70(b): owner OR manager. The widened studios UPDATE policy is the
  // enforcement; this decides what to offer, and a front desk / instructor who
  // types the URL gets an explanation rather than a form that will refuse them.
  if (!isManagerUp(ctx.role)) {
    return (
      <AppShell {...shell} title="Member app">
        <Empty>
          How the member app looks is set by an owner or a manager. You are signed in
          as {ctx.role.replace("_", " ")}.
        </Empty>
      </AppShell>
    );
  }

  const [{ data: studio }, { data: settings }] = await Promise.all([
    supabase
      .from("studios")
      .select("name, theme_preset, accent_color, logo_url, login_image_url, login_image_focus_x, login_image_focus_y, contact_email, contact_phone, login_tagline, install_welcome")
      .eq("id", ctx.studioId)
      .maybeSingle(),
    supabase
      .from("studio_settings")
      .select("public_instructor_name, time_format")
      .eq("studio_id", ctx.studioId)
      .maybeSingle(),
  ]);

  return (
    <AppShell {...shell} title="Member app">
      <p className="mb-6 max-w-[54ch] text-[13px] leading-[20px] text-ink-2">
        This is what your members see on their phones. It does not change
        anything in here — the studio side stays as it is, so support and
        screenshots always look the same.
      </p>
      <BrandingForm
        studioName={studio?.name ?? "your studio"}
        preset={(studio?.theme_preset ?? "warm") as PresetKey}
        accent={studio?.accent_color ?? null}
        logoUrl={studio?.logo_url ?? null}
        loginFocusX={studio?.login_image_focus_x ?? 50}
        loginFocusY={studio?.login_image_focus_y ?? 50}
        loginImageUrl={studio?.login_image_url ?? null}
        contactEmail={studio?.contact_email ?? ""}
        contactPhone={studio?.contact_phone ?? ""}
        loginTagline={studio?.login_tagline ?? ""}
        installWelcome={studio?.install_welcome ?? ""}
        publicInstructorName={(settings?.public_instructor_name ?? "first") as "first" | "full"}
        timeFormat={(settings?.time_format ?? "24h") as "24h" | "12h"}
      />
    </AppShell>
  );
}
