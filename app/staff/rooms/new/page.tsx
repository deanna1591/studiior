import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, NavLink } from "@/components/ui";
import RoomForm from "../form";

export const dynamic = "force-dynamic";

export default async function NewRoom() {
  const screen = await staffScreen("/rooms");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return (
      <AppShell {...shell} title="Rooms">
        <Denied what="Managing rooms" role={ctx.role} />
      </AppShell>
    );
  }
  return (
    <AppShell {...shell} title="Add a room" actions={<NavLink href="/rooms">Back to rooms</NavLink>}>
      <RoomForm mode="create" draft={{ name: "", capacity: 0, color: null, status: "active" }} />
    </AppShell>
  );
}
