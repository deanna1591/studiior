import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { SetupShell, SetupRow } from "@/components/setup-list";

export const dynamic = "force-dynamic";

export default async function RoomsList() {
  const screen = await staffScreen("/rooms");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Rooms"><Denied what="Managing rooms" role={ctx.role} /></AppShell>;
  }

  const { data: rooms } = await supabase
    .from("rooms").select("id, name, capacity, color, status").order("status").order("name");

  return (
    <SetupShell
      shell={shell}
      title="Rooms"
      blurb="Where classes happen. A room's capacity becomes the default for any class you put in it, and it cannot be cut below what is already booked."
      newHref="/rooms/new" newLabel="Add a room" count={(rooms ?? []).length}
      empty="No rooms yet — a class needs one before you can schedule it."
    >
      {(rooms ?? []).map((r) => (
        <SetupRow key={r.id} href={`/rooms/${r.id}`} name={r.name}
                  meta={`Holds ${r.capacity}`} archived={r.status !== "active"} />
      ))}
    </SetupShell>
  );
}
