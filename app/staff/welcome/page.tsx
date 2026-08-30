import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffAccess } from "@/lib/auth";
import StaffAccessGate from "@/components/staff-access-gate";
import WizardForms from "./forms";

export const dynamic = "force-dynamic";

/**
 * Steps 2 and 3. Step 1 was accepting the invite, which created the account.
 *
 * Linear and blocking: every other staff screen goes through
 * requireOnboarded(), which sends people back here until
 * onboarding_completed_at is set at the end of step 3. The Product Bible ends
 * the wizard at the dashboard, not at a fully configured studio — the rest is
 * the dashboard checklist.
 */
export default async function Welcome({ searchParams }: { searchParams: { step?: string } }) {
  const access = await getStaffAccess();
  if (access.kind !== "staff") return <StaffAccessGate access={access} />;
  const ctx = access.ctx;
  if (ctx.onboardingComplete) redirect("/");

  const supabase = createClient();
  const [{ data: studio }, { data: settings }] = await Promise.all([
    supabase.from("studios").select("name, slug, timezone, currency, country")
      .eq("id", ctx.studioId).maybeSingle(),
    supabase.from("studio_settings")
      .select("booking_window_days, cancellation_cutoff_minutes, require_waiver")
      .eq("studio_id", ctx.studioId).maybeSingle(),
  ]);
  if (!studio || !settings) redirect("/login");

  const step = searchParams.step === "3" ? 3 : 2;

  return (
    <div className="mx-auto max-w-lg px-5 py-14">
      <p className="text-xs font-semibold uppercase tracking-wide text-stone-500">
        Step {step} of 3
      </p>
      <h1 className="mt-1 text-xl font-semibold tracking-tight">
        {step === 2 ? "Confirm your studio" : "Booking basics"}
      </h1>
      <p className="mb-6 mt-1 text-sm leading-relaxed text-stone-600">
        {step === 2
          ? "We pre-filled this from your invite. Change anything that is wrong — the slug decides your member app address."
          : "Three settings to get you booking. Everything else has a sensible default and can wait."}
      </p>
      <WizardForms step={step} studio={studio} settings={settings} />
    </div>
  );
}
