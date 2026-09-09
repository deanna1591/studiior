import { notFound } from "next/navigation";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, NavLink } from "@/components/ui";
import ArchiveControls from "@/app/staff/archive-form";
import TypeInstructors from "./instructors";
import ClassTypeForm from "../form";

export const dynamic = "force-dynamic";

export default async function EditClassType({ params }: { params: { id: string } }) {
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
  const { data: t } = await supabase.from("class_types")
    .select("id, name, description, duration_minutes, default_capacity, difficulty, color, status, image_url")
    .eq("id", params.id).maybeSingle();
  if (!t) notFound();

  const [{ data: people }, { data: quals }] = await Promise.all([
    supabase.from("instructors").select("id, display_name")
      .eq("status", "active").order("display_name"),
    supabase.from("instructor_class_types").select("instructor_id")
      .eq("class_type_id", t.id),
  ]);
  return (
    <AppShell {...shell} title={t.name} actions={<NavLink href="/class-types">Back to class types</NavLink>}>
      <p className="mb-5 text-[13px] leading-[20px] text-ink-2">{`${t.duration_minutes} min · holds ${t.default_capacity} · ${t.status}`}</p>
      <ClassTypeForm mode="edit" draft={t} />
      <TypeInstructors
        classTypeId={t.id}
        typeName={t.name}
        instructors={people ?? []}
        selected={(quals ?? []).map((q) => q.instructor_id)}
        canEdit
      />
      <ArchiveControls kind="class_type" id={t.id} archived={t.status !== "active"} />
    </AppShell>
  );
}
