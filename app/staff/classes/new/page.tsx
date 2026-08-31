import { redirect } from "next/navigation";
import { staffScreen } from "@/lib/screen";
import { AppShell, NavLink } from "@/components/ui";
import CreateClassForm from "./form";

export const dynamic = "force-dynamic";

export default async function NewClass() {
  const screen = await staffScreen("/classes/new");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  const [{ data: classTypes }, { data: instructors }, { data: rooms }] = await Promise.all([
    supabase.from("class_types").select("id, name, default_capacity, duration_minutes")
      .eq("status", "active").order("name"),
    supabase.from("instructors").select("id, display_name").eq("status", "active").order("display_name"),
    supabase.from("rooms").select("id, name, capacity").eq("status", "active").order("name"),
  ]);

  return (
    <AppShell {...shell} title="Add a class"
              actions={<NavLink href="/">Back to schedule</NavLink>}>
      <p className="mb-5 text-[13px] leading-[20px] text-ink-2">
        Times are {ctx.timeZone.replace("_", " ")}, and stay that way across the
        clock change — a 07:00 class is 07:00 in March and in November.
      </p>
      <CreateClassForm
        classTypes={classTypes ?? []}
        instructors={instructors ?? []}
        rooms={rooms ?? []}
      />
    </AppShell>
  );
}
