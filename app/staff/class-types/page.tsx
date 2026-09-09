import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { SetupShell, SetupRow, ArchivedSection } from "@/components/setup-list";

export const dynamic = "force-dynamic";

export default async function ClassTypesList() {
  const screen = await staffScreen("/class-types");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Class types"><Denied what="Managing class types" role={ctx.role} /></AppShell>;
  }

  const { data: types } = await supabase.from("class_types")
    .select("id, name, duration_minutes, default_capacity, difficulty, status")
    .order("status").order("name");

  // Split rather than greyed in place. An archived record among the live ones
  // reads as a broken row; below its own heading it reads as a retired one,
  // which is what it is.
  const live = (types ?? []).filter((x) => x.status === "active");
  const gone = (types ?? []).filter((x) => x.status !== "active");

  return (
    <SetupShell
      shell={shell}
      title="Class types"
      blurb="What you teach. Every class on the schedule is one of these, and it supplies the default length and capacity."
      newHref="/class-types/new" newLabel="Add a class type" count={live.length}
      empty="No class types yet — you need one before you can put a class on."
      archived={
        <ArchivedSection noun="class type" count={gone.length}>
        {gone.map((t) => (
          <SetupRow key={t.id} href={`/class-types/${t.id}`} name={t.name}
                        meta={`${t.duration_minutes} min · holds ${t.default_capacity}${t.difficulty ? ` · ${t.difficulty}` : ""}`} archived />
        ))}
        </ArchivedSection>
      }
    >
      {live.map((t) => (
        <SetupRow key={t.id} href={`/class-types/${t.id}`} name={t.name}
                  meta={`${t.duration_minutes} min · holds ${t.default_capacity}${t.difficulty ? ` · ${t.difficulty}` : ""}`} />
      ))}
    </SetupShell>
  );
}
