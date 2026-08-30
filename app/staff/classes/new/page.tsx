import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { requireOnboardedStaff } from "@/lib/auth";
import { Shell, NavLink } from "@/components/ui";
import CreateClassForm from "./form";

export const dynamic = "force-dynamic";

export default async function NewClass() {
  const ctx = await requireOnboardedStaff();

  const supabase = createClient();
  const [{ data: classTypes }, { data: instructors }, { data: rooms }] = await Promise.all([
    supabase.from("class_types").select("id, name, default_capacity, duration_minutes")
      .eq("status", "active").order("name"),
    supabase.from("instructors").select("id, display_name").eq("status", "active").order("display_name"),
    supabase.from("rooms").select("id, name, capacity").eq("status", "active").order("name"),
  ]);

  return (
    <Shell
      title="Create a class"
      subtitle={`${ctx.studioName} · times are ${ctx.timeZone}`}
      right={<NavLink href="/">Back to week</NavLink>}
    >
      <CreateClassForm
        classTypes={classTypes ?? []}
        instructors={instructors ?? []}
        rooms={rooms ?? []}
      />
    </Shell>
  );
}
