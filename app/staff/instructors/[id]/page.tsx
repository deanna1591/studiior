import { notFound } from "next/navigation";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, NavLink, SectionLabel } from "@/components/ui";
import ArchiveControls from "@/app/staff/archive-form";
import InstructorForm from "../form";
import RatePanel, { type RateVersion } from "./rate-panel";

export const dynamic = "force-dynamic";

export default async function EditInstructor({ params }: { params: { id: string } }) {
  const screen = await staffScreen("/instructors");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return (
      <AppShell {...shell} title="Instructors">
        <Denied what="Managing instructors" role={ctx.role} />
      </AppShell>
    );
  }
  const { data: i } = await supabase.from("instructors")
    .select("id, display_name, bio, avatar_url, color, certifications, staff_id, status")
    .eq("id", params.id).maybeSingle();
  if (!i) notFound();
  const certs = Array.isArray(i.certifications) ? (i.certifications as string[]) : [];

  // The Pay section only exists for a studio that runs payroll (Decision 22) —
  // a studio paying in its own books sees nothing of it.
  const [{ data: usesPayroll }, { data: versions }, { count: activeCount }] = await Promise.all([
    supabase.rpc("studio_uses_payroll", { p_studio_id: ctx.studioId }),
    supabase.from("instructor_rate_versions")
      .select("effective_from, base_rate_cents, per_head_rate_cents, per_head_threshold, full_house_bonus_cents, private_rate_cents, duo_rate_cents, trio_rate_cents, pay_tier")
      .eq("instructor_id", params.id).order("effective_from", { ascending: false }),
    supabase.from("instructors").select("id", { count: "exact", head: true })
      .eq("studio_id", ctx.studioId).eq("status", "active"),
  ]);
  const payrollOn = usesPayroll === true;
  const history = (versions ?? []) as RateVersion[];
  const today = new Date().toISOString().slice(0, 10);
  const tomorrow = new Date(Date.now() + 86400000).toISOString().slice(0, 10);
  // The latest version is what the screen shows and what "copy to all" sends —
  // a rate a studio has just set to start tomorrow is on file even though it is
  // not yet in force. "No rate" means there are genuinely no versions.
  const current = history[0] ?? null;

  return (
    <AppShell {...shell} title={i.display_name} actions={<><NavLink href={`/instructors/${i.id}/availability`}>Availability &amp; commitment</NavLink>{" "}<NavLink href="/instructors">Back to instructors</NavLink></>}>
      <p className="mb-5 text-[13px] leading-[20px] text-ink-2">{i.status}</p>
      <InstructorForm mode="edit" draft={{
        id: i.id, display_name: i.display_name, bio: i.bio, avatar_url: i.avatar_url,
        color: i.color, certifications: certs, status: i.status, hasLogin: i.staff_id != null }} />

      {payrollOn && (
        <div className="mt-8">
          <SectionLabel>Pay</SectionLabel>
          <div className="mt-3">
            <RatePanel instructorId={i.id} currency={ctx.currency} current={current}
                       history={history} activeCount={activeCount ?? 0} tomorrow={tomorrow} today={today} />
          </div>
        </div>
      )}

      <ArchiveControls kind="instructor" id={i.id} archived={i.status !== "active"} />
    </AppShell>
  );
}
