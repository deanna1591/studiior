import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, Empty, NavLink, SectionLabel } from "@/components/ui";
import { fmtTime, fmtDayLong } from "@/lib/time";
import { DecideCoverForm } from "./form";

export const dynamic = "force-dynamic";

/**
 * Cover requests waiting on an answer.
 *
 * Decision 18: staff always approve, which makes an unanswered request its own
 * emergency — a class nobody looked at is a class nobody teaches. So the urgent
 * ones are separated out and said in words rather than sorted to the top and
 * left to be noticed.
 */
export default async function Cover() {
  const screen = await staffScreen("/shifts/cover");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return (
      <AppShell {...shell} title="Cover requests">
        <Denied what="Answering cover requests" role={ctx.role} />
      </AppShell>
    );
  }

  const [{ data: pending }, { data: settled }, { data: instructors }, { data: settings }] =
    await Promise.all([
      supabase.from("cover_requests")
        // ONE string literal, not a concatenation. `"a, " + "b"` is typed
        // `string`, not a literal, so the client cannot infer the row shape and
        // every field comes back as GenericStringError.
        .select(`id, reason, requested_at, escalated_at, occurrence_id, instructor_id,
                 instructors!cover_requests_instructor_id_fkey(display_name),
                 class_occurrences(id, name, starts_at, ends_at, booked_count, rooms(name))`)
        .eq("status", "pending").order("requested_at"),
      supabase.from("cover_requests")
        .select(`id, status, resolution, decided_at,
                 instructors!cover_requests_instructor_id_fkey(display_name),
                 class_occurrences(name, starts_at)`)
        .neq("status", "pending").order("decided_at", { ascending: false }).limit(8),
      supabase.from("instructors").select("id, display_name")
        .eq("status", "active").order("display_name"),
      // studio_settings directly, not studio_member_settings(): that function
      // is the six-field member-facing subset and does not carry this. Reading
      // it there would have silently fallen back to the default 4 forever.
      supabase.from("studio_settings").select("cover_escalation_hours")
        .eq("studio_id", ctx.studioId).maybeSingle(),
    ]);

  const escalation = settings?.cover_escalation_hours ?? 4;
  const now = Date.now();

  const rows = (pending ?? []).filter((r) => r.class_occurrences);
  const hoursTo = (iso: string) => (new Date(iso).getTime() - now) / 3600e3;
  const urgent = rows.filter((r) => hoursTo(r.class_occurrences!.starts_at) <= escalation);
  const rest = rows.filter((r) => hoursTo(r.class_occurrences!.starts_at) > escalation);

  // Availability per candidate per class, asked rather than assumed — the same
  // answer the person deciding would get from the scheduler.
  // TWO QUESTIONS, and they are different. `valid` is whether this person's
  // stated pattern is in force on that DATE at all — a hard gate, so somebody
  // valid only for November is not offered for a December class. `free` is
  // whether they said they are around at that TIME, which stays context rather
  // than a filter, per Decision 9.
  const freeMap = new Map<string, Set<string>>();
  const validMap = new Map<string, Set<string>>();
  await Promise.all(rows.map(async (r) => {
    const o = r.class_occurrences!;
    const day = o.starts_at.slice(0, 10);
    const free = new Set<string>();
    const valid = new Set<string>();
    await Promise.all((instructors ?? []).map(async (x) => {
      if (x.id === r.instructor_id) return;
      const [{ data: ok }, { data: inWindow }] = await Promise.all([
        supabase.rpc("instructor_available_at", {
          p_instructor_id: x.id, p_starts_at: o.starts_at, p_ends_at: o.ends_at,
        }),
        supabase.rpc("instructor_valid_on", { p_instructor_id: x.id, p_on: day }),
      ]);
      if (inWindow !== false) valid.add(x.id);
      if (ok !== false) free.add(x.id);
    }));
    freeMap.set(r.id, free);
    validMap.set(r.id, valid);
  }));

  const when = (iso: string) => `${fmtDayLong(iso, ctx.timeZone)}, ${fmtTime(iso, ctx.timeZone)}`;
  const away = (iso: string) => {
    const h = hoursTo(iso);
    return h < 1 ? `${Math.max(0, Math.round(h * 60))} minutes`
         : h < 48 ? `${Math.round(h)} hours`
         : `${Math.round(h / 24)} days`;
  };

  const Card = ({ r, loud }: { r: (typeof rows)[number]; loud: boolean }) => {
    const o = r.class_occurrences!;
    const free = freeMap.get(r.id) ?? new Set<string>();
    const valid = validMap.get(r.id) ?? new Set<string>();
    return (
      <li className={`rounded-xl p-4 ${loud ? "" : "bg-paper"}`}
          style={loud ? { background: "var(--coral-tint)" } : undefined}>
        <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
          <p className="text-[15px] font-semibold leading-6 text-ink">
            {r.instructors?.display_name ?? "Somebody"} needs cover for {o.name}
          </p>
          <p className="num text-[13px] leading-[20px] text-ink-2">
            {when(o.starts_at)} · in {away(o.starts_at)}
          </p>
        </div>
        <p className="mt-0.5 text-[13px] leading-[20px] text-ink-2">
          {o.rooms?.name ? `${o.rooms.name} · ` : ""}
          {o.booked_count > 0
            ? `${o.booked_count} booked`
            : "nobody booked"}
          {r.reason ? ` · “${r.reason}”` : ""}
        </p>
        {/* The single most important sentence on this screen. */}
        <p className="mt-1.5 text-[13px] leading-[20px] text-ink">
          {r.instructors?.display_name ?? "They"} {loud ? "is still on this class" : "is still teaching it"} until you answer.
        </p>
        <DecideCoverForm
          requestId={r.id}
          bookedCount={o.booked_count}
          instructors={(instructors ?? [])
            .filter((x) => x.id !== r.instructor_id)
            // Outside their availability DATES is not offered at all.
            .filter((x) => valid.has(x.id))
            .map((x) => ({ ...x, free: free.has(x.id) }))}
        />
      </li>
    );
  };

  return (
    <AppShell {...shell} title="Cover requests"
              actions={<NavLink href="/shifts/applications">Open shift applications</NavLink>}>
      {urgent.length > 0 && (
        <section className="mb-7">
          <SectionLabel>Needs deciding now</SectionLabel>
          <p className="mb-3 text-[13px] leading-[20px] text-ink-2">
            {urgent.length === 1 ? "This class starts" : "These classes start"} within{" "}
            <span className="num">{escalation}</span> hours and nobody has answered.
          </p>
          <ul className="space-y-3">
            {urgent.map((r) => <Card key={r.id} r={r} loud />)}
          </ul>
        </section>
      )}

      <SectionLabel>Waiting on you</SectionLabel>
      {rest.length === 0 ? (
        <Empty>
          {urgent.length > 0
            ? "Nothing else waiting."
            : "No cover requests. Instructors ask from their own shifts screen."}
        </Empty>
      ) : (
        <ul className="space-y-3">{rest.map((r) => <Card key={r.id} r={r} loud={false} />)}</ul>
      )}

      {(settled ?? []).length > 0 && (
        <section className="mt-8">
          <SectionLabel>Recently answered</SectionLabel>
          <ul className="space-y-1">
            {(settled ?? []).map((r) => (
              <li key={r.id} className="flex flex-wrap items-baseline justify-between gap-x-3 rounded-lg px-3.5 py-2.5 text-[13px] leading-[20px]">
                <span className="text-ink-2">
                  {r.instructors?.display_name} · {r.class_occurrences?.name}
                  {r.class_occurrences && <span className="num"> · {when(r.class_occurrences.starts_at)}</span>}
                </span>
                <span className="text-ink-3">
                  {r.status === "approved"
                    ? r.resolution === "opened" ? "opened up" : "covered"
                    : r.status === "declined" ? "declined" : "taken back"}
                </span>
              </li>
            ))}
          </ul>
        </section>
      )}
    </AppShell>
  );
}
