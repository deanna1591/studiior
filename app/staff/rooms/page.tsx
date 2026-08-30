import { createClient } from "@/lib/supabase/server";
import { getStaffAccess, requireOnboarded, isManagerUp } from "@/lib/auth";
import StaffAccessGate from "@/components/staff-access-gate";
import { Shell, NavLink } from "@/components/ui";
import { SetupShell, SetupRow } from "@/components/setup-list";

export const dynamic = "force-dynamic";

export default async function RoomsList() {
  const access = await getStaffAccess();
  if (access.kind !== "staff") return <StaffAccessGate access={access} />;
  const ctx = requireOnboarded(access.ctx);
  if (!isManagerUp(ctx.role)) {
    return (
      <Shell title="Rooms" subtitle={ctx.studioName} right={<NavLink href="/">Back to week</NavLink>}>
        <p className="text-sm text-stone-600">
          Rooms are managed by owners and managers. Your role is {ctx.role.replace("_", " ")}.
        </p>
      </Shell>
    );
  }

  const supabase = createClient();
  const { data: rooms } = await supabase
    .from("rooms").select("id, name, capacity, color, status").order("status").order("name");

  return (
    <SetupShell
      title="Rooms" subtitle={`${ctx.studioName} · where classes happen`}
      newHref="/rooms/new" newLabel="Add a room" count={(rooms ?? []).length}
      empty="No rooms yet. A class needs one, and its capacity becomes the class default."
    >
      {(rooms ?? []).map((r) => (
        <SetupRow key={r.id} href={`/rooms/${r.id}`} name={r.name}
                  meta={`Holds ${r.capacity}`} archived={r.status !== "active"} />
      ))}
    </SetupShell>
  );
}
