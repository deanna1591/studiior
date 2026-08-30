import { notFound } from "next/navigation";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, NavLink } from "@/components/ui";
import InstructorForm from "../form";

export const dynamic = "force-dynamic";

export default async function EditInstructor({ params }: { params: { id: string } }) {
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
  const { data: i } = await supabase.from("instructors")
    .select("id, display_name, bio, avatar_url, color, certifications, staff_id, status")
    .eq("id", params.id).maybeSingle();
  if (!i) notFound();
  const certs = Array.isArray(i.certifications) ? (i.certifications as string[]) : [];
  return (
    <AppShell {...shell} title={i.display_name} actions={<NavLink href="/instructors">Back to instructors</NavLink>}>
      <p className="mb-5 text-[13px] leading-[20px] text-ink-2">{i.status}</p>
      <InstructorForm mode="edit" draft={{
        id: i.id, display_name: i.display_name, bio: i.bio, avatar_url: i.avatar_url,
        color: i.color, certifications: certs, status: i.status, hasLogin: i.staff_id != null }} />
    </AppShell>
  );
}
