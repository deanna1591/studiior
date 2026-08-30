import { notFound } from "next/navigation";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, NavLink } from "@/components/ui";
import RoomForm from "../form";

export const dynamic = "force-dynamic";

export default async function EditRoom({ params }: { params: { id: string } }) {
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
  const { data: room } = await supabase.from("rooms")
    .select("id, name, capacity, color, status").eq("id", params.id).maybeSingle();
  if (!room) notFound();
  return (
    <AppShell {...shell} title={room.name} actions={<NavLink href="/rooms">Back to rooms</NavLink>}>
      <p className="mb-5 text-[13px] leading-[20px] text-ink-2">{`Holds ${room.capacity} · ${room.status}`}</p>
      <RoomForm mode="edit" draft={room} />
    </AppShell>
  );
}
