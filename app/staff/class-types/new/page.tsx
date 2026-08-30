import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, NavLink } from "@/components/ui";
import ClassTypeForm from "../form";

export const dynamic = "force-dynamic";

export default async function NewClassType() {
  const screen = await staffScreen("/class-types");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return (
      <AppShell {...shell} title="Class types">
        <Denied what="Managing class types" role={ctx.role} />
      </AppShell>
    );
  }
  return (
    <AppShell {...shell} title="Add a class type" actions={<NavLink href="/class-types">Back to class types</NavLink>}>
      <ClassTypeForm mode="create" draft={{
        name: "", description: null, duration_minutes: 50, default_capacity: 8,
        difficulty: null, color: null, status: "active" }} />
    </AppShell>
  );
}
