import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { SetupShell, SetupRow } from "@/components/setup-list";

export const dynamic = "force-dynamic";

export default async function InstructorsList() {
  const screen = await staffScreen("/instructors");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Instructors"><Denied what="Managing instructors" role={ctx.role} /></AppShell>;
  }

  const { data: people } = await supabase.from("instructors")
    .select("id, display_name, bio, certifications, staff_id, status")
    .order("status").order("display_name");

  return (
    <SetupShell
      shell={shell}
      title="Instructors"
      blurb="Who teaches. An instructor is a teaching record — they do not need a login, and adding one here does not invite them."
      newHref="/instructors/new" newLabel="Add an instructor" count={(people ?? []).length}
      empty="No instructors yet — a class can go on without one, but the roster reads better with a name on it."
    >
      {(people ?? []).map((p) => {
        const certs = Array.isArray(p.certifications) ? p.certifications.length : 0;
        return (
          <SetupRow key={p.id} href={`/instructors/${p.id}`} name={p.display_name}
                    meta={[
                      p.staff_id ? "Has a login" : "Teaching record only",
                      certs ? `${certs} certification${certs === 1 ? "" : "s"}` : null,
                    ].filter(Boolean).join(" · ")}
                    archived={p.status !== "active"} />
        );
      })}
    </SetupShell>
  );
}
