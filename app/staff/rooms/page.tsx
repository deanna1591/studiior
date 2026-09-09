import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { SetupShell, SetupRow, ArchivedSection } from "@/components/setup-list";

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

  // Split rather than greyed in place. An archived record among the live ones
  // reads as a broken row; below its own heading it reads as a retired one,
  // which is what it is.
  const live = (rooms ?? []).filter((x) => x.status === "active");
  const gone = (rooms ?? []).filter((x) => x.status !== "active");

  return (
    <SetupShell
      shell={shell}
      title="Rooms"
      blurb="Where classes happen. A room's capacity becomes the default for any class you put in it, and it cannot be cut below what is already booked."
      newHref="/rooms/new" newLabel="Add a room" count={live.length}
      empty="No rooms yet — a class needs one before you can schedule it."
      archived={
        <ArchivedSection noun="room" count={gone.length}>
        {gone.map((r) => (
          <SetupRow key={r.id} href={`/rooms/${r.id}`} name={r.name}
                        meta={`Holds ${r.capacity}`} archived />
        ))}
        </ArchivedSection>
      }
    >
      {live.map((r) => (
        <SetupRow key={r.id} href={`/rooms/${r.id}`} name={r.name}
                  meta={`Holds ${r.capacity}`} />
      ))}
    </SetupShell>
  );
}
