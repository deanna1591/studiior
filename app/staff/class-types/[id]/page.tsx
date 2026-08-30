import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffAccess, requireOnboarded, isManagerUp } from "@/lib/auth";
import StaffAccessGate from "@/components/staff-access-gate";
import { Shell, NavLink } from "@/components/ui";
import ClassTypeForm from "../form";

export const dynamic = "force-dynamic";

export default async function EditClassType({ params }: { params: { id: string } }) {
  const access = await getStaffAccess();
  if (access.kind !== "staff") return <StaffAccessGate access={access} />;
  const ctx = requireOnboarded(access.ctx);
  if (!isManagerUp(ctx.role)) {
    return <Shell title="Class type" subtitle={ctx.studioName} right={<NavLink href="/class-types">Back</NavLink>}>
      <p className="text-sm text-stone-600">Owners and managers only.</p></Shell>;
  }
  const supabase = createClient();
  const { data: t } = await supabase.from("class_types")
    .select("id, name, description, duration_minutes, default_capacity, difficulty, color, status")
    .eq("id", params.id).maybeSingle();
  if (!t) notFound();
  return (
    <Shell title={t.name} subtitle={`${t.duration_minutes} min · holds ${t.default_capacity} · ${t.status}`}
           right={<NavLink href="/class-types">Back to class types</NavLink>}>
      <ClassTypeForm mode="edit" draft={t} />
    </Shell>
  );
}
