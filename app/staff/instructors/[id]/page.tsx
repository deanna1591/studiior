import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffAccess, requireOnboarded, isManagerUp } from "@/lib/auth";
import StaffAccessGate from "@/components/staff-access-gate";
import { Shell, NavLink } from "@/components/ui";
import InstructorForm from "../form";

export const dynamic = "force-dynamic";

export default async function EditInstructor({ params }: { params: { id: string } }) {
  const access = await getStaffAccess();
  if (access.kind !== "staff") return <StaffAccessGate access={access} />;
  const ctx = requireOnboarded(access.ctx);
  if (!isManagerUp(ctx.role)) {
    return <Shell title="Instructor" subtitle={ctx.studioName} right={<NavLink href="/instructors">Back</NavLink>}>
      <p className="text-sm text-stone-600">Owners and managers only.</p></Shell>;
  }
  const supabase = createClient();
  const { data: i } = await supabase.from("instructors")
    .select("id, display_name, bio, avatar_url, color, certifications, staff_id, status")
    .eq("id", params.id).maybeSingle();
  if (!i) notFound();
  const certs = Array.isArray(i.certifications) ? (i.certifications as string[]) : [];
  return (
    <Shell title={i.display_name} subtitle={i.status}
           right={<NavLink href="/instructors">Back to instructors</NavLink>}>
      <InstructorForm mode="edit" draft={{
        id: i.id, display_name: i.display_name, bio: i.bio, avatar_url: i.avatar_url,
        color: i.color, certifications: certs, status: i.status, hasLogin: i.staff_id != null }} />
    </Shell>
  );
}
