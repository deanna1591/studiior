import { notFound } from "next/navigation";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, NavLink } from "@/components/ui";
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
  return (
    <AppShell {...shell} title={t.name} actions={<NavLink href="/class-types">Back to class types</NavLink>}>
      <p className="mb-5 text-[13px] leading-[20px] text-ink-2">{`${t.duration_minutes} min · holds ${t.default_capacity} · ${t.status}`}</p>
      <ClassTypeForm mode="edit" draft={t} />
    </AppShell>
  );
}
