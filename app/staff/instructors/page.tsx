import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import Link from "next/link";
import { AppShell, Denied } from "@/components/ui";
import { SetupShell, SetupRow, ArchivedSection } from "@/components/setup-list";

export const dynamic = "force-dynamic";

export default async function InstructorsList() {
  const screen = await staffScreen("/instructors");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Instructors"><Denied what="Managing instructors" role={ctx.role} /></AppShell>;
  }

  const [{ data: people }, { data: cycle }] = await Promise.all([
    supabase.from("instructors")
      .select("id, display_name, bio, certifications, staff_id, status")
      .order("status").order("display_name"),
    // Decision 46: the collected month's availability state per instructor
    // (availability_cycle defaults to next month — the same month /availability
    // reviews). Manager-up, which this page already is.
    supabase.rpc("availability_cycle", { p_studio_id: ctx.studioId }),
  ]);

  // Decision 46: per-instructor state for the line on each row.
  const cycleRows = ((cycle as { instructors?: { instructor_id: string; status: string }[] } | null)?.instructors) ?? [];
  const stateOf = new Map(cycleRows.map((r) => [r.instructor_id, r.status]));
  const availabilityLine = (id: string): string => {
    switch (stateOf.get(id)) {
      case "submitted": return "Availability: submitted · waiting for you";
      case "approved": return "Availability: approved";
      case "changes_requested": return "Availability: sent back";
      default: return "Availability: nothing yet";
    }
  };

  // Split rather than greyed in place. An archived instructor among the live
  // ones reads as a broken row; below its own heading it reads as somebody who
  // used to teach here, which is what they are.
  const live = (people ?? []).filter((x) => x.status === "active");
  const gone = (people ?? []).filter((x) => x.status !== "active");
  const meta = (p: { staff_id: string | null; certifications: unknown }) => {
    const certs = Array.isArray(p.certifications) ? p.certifications.length : 0;
    return [
      p.staff_id ? "Has a login" : "Teaching record only",
      certs ? `${certs} certification${certs === 1 ? "" : "s"}` : null,
    ].filter(Boolean).join(" \u00b7 ");
  };

  return (
    <SetupShell
      shell={shell}
      title="Instructors"
      blurb="Who teaches. An instructor is a teaching record — they do not need a login, and adding one here does not invite them."
      afterBlurb={
        <span className="flex gap-4">
          <Link href="/instructors/access" className="text-[13px] text-lime-text underline underline-offset-4 hover:text-lime-text2">Who can sign in →</Link>
          <Link href="/availability" className="text-[13px] text-lime-text underline underline-offset-4 hover:text-lime-text2">Review availability →</Link>
        </span>
      }
      newHref="/instructors/new" newLabel="Add an instructor" count={live.length}
      empty="No instructors yet — a class can go on without one, but the roster reads better with a name on it."
      archived={
        <ArchivedSection noun="instructor" count={gone.length}>
          {gone.map((p) => (
            <SetupRow key={p.id} href={`/instructors/${p.id}`} name={p.display_name}
                      meta={meta(p)} archived />
          ))}
        </ArchivedSection>
      }
    >
      {live.map((p) => (
        <SetupRow key={p.id} href={`/instructors/${p.id}`} name={p.display_name}
                  meta={`${meta(p)} · ${availabilityLine(p.id)}`} />
      ))}
    </SetupShell>
  );
}
