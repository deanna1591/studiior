import { createClient } from "@/lib/supabase/server";
import { getStaffAccess, requireOnboarded, isManagerUp } from "@/lib/auth";
import StaffAccessGate from "@/components/staff-access-gate";
import { Shell, NavLink } from "@/components/ui";
import { SetupShell, SetupRow } from "@/components/setup-list";

export const dynamic = "force-dynamic";

export default async function InstructorsList() {
  const access = await getStaffAccess();
  if (access.kind !== "staff") return <StaffAccessGate access={access} />;
  const ctx = requireOnboarded(access.ctx);
  if (!isManagerUp(ctx.role)) {
    return <Shell title="Instructors" subtitle={ctx.studioName} right={<NavLink href="/">Back to week</NavLink>}>
      <p className="text-sm text-stone-600">
        Instructor records are managed by owners and managers. Your role is {ctx.role.replace("_", " ")}.
      </p></Shell>;
  }
  const supabase = createClient();
  const { data: people } = await supabase.from("instructors")
    .select("id, display_name, bio, certifications, staff_id, status")
    .order("status").order("display_name");

  return (
    <SetupShell
      title="Instructors" subtitle={`${ctx.studioName} · who teaches`}
      newHref="/instructors/new" newLabel="Add an instructor" count={(people ?? []).length}
      empty="No instructors yet. A class can be scheduled without one, but the roster reads better with a name on it."
    >
      {(people ?? []).map((p) => {
        const certs = Array.isArray(p.certifications) ? p.certifications.length : 0;
        return (
          <SetupRow key={p.id} href={`/instructors/${p.id}`} name={p.display_name}
                    meta={[
                      p.staff_id ? "has a login" : "teaching record only",
                      certs ? `${certs} certification${certs === 1 ? "" : "s"}` : null,
                    ].filter(Boolean).join(" · ")}
                    archived={p.status !== "active"} />
        );
      })}
    </SetupShell>
  );
}
