import { getStaffAccess, requireOnboarded, isManagerUp } from "@/lib/auth";
import StaffAccessGate from "@/components/staff-access-gate";
import { Shell, NavLink } from "@/components/ui";
import RoomForm from "../form";

export const dynamic = "force-dynamic";

export default async function NewRoom() {
  const access = await getStaffAccess();
  if (access.kind !== "staff") return <StaffAccessGate access={access} />;
  const ctx = requireOnboarded(access.ctx);
  if (!isManagerUp(ctx.role)) {
    return <Shell title="Add a room" subtitle={ctx.studioName} right={<NavLink href="/rooms">Back</NavLink>}>
      <p className="text-sm text-stone-600">Owners and managers only.</p></Shell>;
  }
  return (
    <Shell title="Add a room" subtitle={ctx.studioName} right={<NavLink href="/rooms">Back to rooms</NavLink>}>
      <RoomForm mode="create" draft={{ name: "", capacity: 0, color: null, status: "active" }} />
    </Shell>
  );
}
