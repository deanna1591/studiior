import { createClient } from "@/lib/supabase/server";
import { getStaffAccess, requireOnboarded, isManagerUp } from "@/lib/auth";
import StaffAccessGate from "@/components/staff-access-gate";
import { Shell, NavLink } from "@/components/ui";
import { SetupShell, SetupRow } from "@/components/setup-list";

export const dynamic = "force-dynamic";

export default async function ClassTypesList() {
  const access = await getStaffAccess();
  if (access.kind !== "staff") return <StaffAccessGate access={access} />;
  const ctx = requireOnboarded(access.ctx);
  if (!isManagerUp(ctx.role)) {
    return <Shell title="Class types" subtitle={ctx.studioName} right={<NavLink href="/">Back to week</NavLink>}>
      <p className="text-sm text-stone-600">
        Class types are managed by owners and managers. Your role is {ctx.role.replace("_", " ")}.
      </p></Shell>;
  }
  const supabase = createClient();
  const { data: types } = await supabase.from("class_types")
    .select("id, name, duration_minutes, default_capacity, difficulty, status")
    .order("status").order("name");

  return (
    <SetupShell
      title="Class types" subtitle={`${ctx.studioName} · what you teach`}
      newHref="/class-types/new" newLabel="Add a class type" count={(types ?? []).length}
      empty="No class types yet. Every class on the schedule is one of these, and it supplies the default length and capacity."
    >
      {(types ?? []).map((t) => (
        <SetupRow key={t.id} href={`/class-types/${t.id}`} name={t.name}
                  meta={`${t.duration_minutes} min · holds ${t.default_capacity}${t.difficulty ? ` · ${t.difficulty}` : ""}`}
                  archived={t.status !== "active"} />
      ))}
    </SetupShell>
  );
}
