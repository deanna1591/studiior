import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, NavLink } from "@/components/ui";
import InstructorForm from "../form";

export const dynamic = "force-dynamic";

export default async function NewInstructor() {
  const screen = await staffScreen("/instructors");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return (
      <AppShell {...shell} title="Instructors">
        <Denied what="Managing instructors" role={ctx.role} />
      </AppShell>
    );
  }
  return (
    <AppShell {...shell} title="Add an instructor" actions={<NavLink href="/instructors">Back to instructors</NavLink>}>
      <InstructorForm mode="create" draft={{
        display_name: "", bio: null, avatar_url: null, color: null,
        certifications: [], status: "active", hasLogin: false }} />
    </AppShell>
  );
}
