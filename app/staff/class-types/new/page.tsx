import { getStaffAccess, requireOnboarded, isManagerUp } from "@/lib/auth";
import StaffAccessGate from "@/components/staff-access-gate";
import { Shell, NavLink } from "@/components/ui";
import ClassTypeForm from "../form";

export const dynamic = "force-dynamic";

export default async function NewClassType() {
  const access = await getStaffAccess();
  if (access.kind !== "staff") return <StaffAccessGate access={access} />;
  const ctx = requireOnboarded(access.ctx);
  if (!isManagerUp(ctx.role)) {
    return <Shell title="Add a class type" subtitle={ctx.studioName} right={<NavLink href="/class-types">Back</NavLink>}>
      <p className="text-sm text-stone-600">Owners and managers only.</p></Shell>;
  }
  return (
    <Shell title="Add a class type" subtitle={ctx.studioName}
           right={<NavLink href="/class-types">Back to class types</NavLink>}>
      <ClassTypeForm mode="create" draft={{
        name: "", description: null, duration_minutes: 50, default_capacity: 8,
        difficulty: null, color: null, status: "active" }} />
    </Shell>
  );
}
