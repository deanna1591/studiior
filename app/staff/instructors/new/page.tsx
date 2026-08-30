import { getStaffAccess, requireOnboarded, isManagerUp } from "@/lib/auth";
import StaffAccessGate from "@/components/staff-access-gate";
import { Shell, NavLink } from "@/components/ui";
import InstructorForm from "../form";

export const dynamic = "force-dynamic";

export default async function NewInstructor() {
  const access = await getStaffAccess();
  if (access.kind !== "staff") return <StaffAccessGate access={access} />;
  const ctx = requireOnboarded(access.ctx);
  if (!isManagerUp(ctx.role)) {
    return <Shell title="Add an instructor" subtitle={ctx.studioName} right={<NavLink href="/instructors">Back</NavLink>}>
      <p className="text-sm text-stone-600">Owners and managers only.</p></Shell>;
  }
  return (
    <Shell title="Add an instructor" subtitle={ctx.studioName}
           right={<NavLink href="/instructors">Back to instructors</NavLink>}>
      <InstructorForm mode="create" draft={{
        display_name: "", bio: null, avatar_url: null, color: null,
        certifications: [], status: "active", hasLogin: false }} />
    </Shell>
  );
}
