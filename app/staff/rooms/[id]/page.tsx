import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffAccess, requireOnboarded, isManagerUp } from "@/lib/auth";
import StaffAccessGate from "@/components/staff-access-gate";
import { Shell, NavLink } from "@/components/ui";
import RoomForm from "../form";

export const dynamic = "force-dynamic";

export default async function EditRoom({ params }: { params: { id: string } }) {
  const access = await getStaffAccess();
  if (access.kind !== "staff") return <StaffAccessGate access={access} />;
  const ctx = requireOnboarded(access.ctx);
  if (!isManagerUp(ctx.role)) {
    return <Shell title="Room" subtitle={ctx.studioName} right={<NavLink href="/rooms">Back</NavLink>}>
      <p className="text-sm text-stone-600">Owners and managers only.</p></Shell>;
  }
  const supabase = createClient();
  const { data: room } = await supabase.from("rooms")
    .select("id, name, capacity, color, status").eq("id", params.id).maybeSingle();
  if (!room) notFound();
  return (
    <Shell title={room.name} subtitle={`Holds ${room.capacity} · ${room.status}`}
           right={<NavLink href="/rooms">Back to rooms</NavLink>}>
      <RoomForm mode="edit" draft={room} />
    </Shell>
  );
}
