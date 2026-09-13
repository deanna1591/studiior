import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import { fmtTime, fmtDayLong } from "@/lib/time";

export const dynamic = "force-dynamic";

type Row = {
  id: string; status: string;
  class_occurrences: { name: string; starts_at: string;
    instructors: { display_name: string } | null } | null;
};

// What happened, as a word and a tone. A past 'booked' with no check-in is left
// quiet — the studio may simply not have marked it.
const OUTCOME: Record<string, { label: string; tone: "good" | "bad" | "quiet" }> = {
  attended:       { label: "Attended", tone: "good" },
  no_show:        { label: "No-show", tone: "bad" },
  late_cancelled: { label: "Late cancel", tone: "bad" },
  cancelled:      { label: "Cancelled", tone: "quiet" },
  waitlisted:     { label: "Didn’t get in", tone: "quiet" },
  booked:         { label: "Booked", tone: "quiet" },
  pending_payment:{ label: "Not paid", tone: "quiet" },
};

export default async function Classes() {
  const { ctx, supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } =
    await memberScreen();

  const { data } = await supabase
    .from("bookings")
    .select("id, status, class_occurrences(name, starts_at, instructors!instructor_id(display_name))")
    .eq("member_id", ctx.memberId)
    .order("booked_at", { ascending: false })
    .limit(200);

  const now = Date.now();
  const rows = ((data ?? []) as unknown as Row[])
    .filter((b) => b.class_occurrences && new Date(b.class_occurrences.starts_at).getTime() < now)
    .sort((a, b) => new Date(b.class_occurrences!.starts_at).getTime() - new Date(a.class_occurrences!.starts_at).getTime());

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href="/account" className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Account
      </Link>
      <h1 className="m-title mb-4 text-ink">Your classes</h1>

      {rows.length === 0 ? (
        <div className="m-card p-5 text-center">
          <p className="m-body text-ink">Nothing yet.</p>
          <p className="m-sub mt-1 text-ink-2">
            Your classes appear here as you take them.{" "}
            <Link href="/book" className="text-lime-text underline underline-offset-4">Book your first</Link>.
          </p>
        </div>
      ) : (
        <ul className="m-card divide-y divide-line overflow-hidden">
          {rows.map((b) => {
            const o = b.class_occurrences!;
            const out = OUTCOME[b.status] ?? { label: b.status, tone: "quiet" as const };
            const color = out.tone === "good" ? "var(--lime-text)"
              : out.tone === "bad" ? "var(--coral-deep)" : "var(--ink-3)";
            return (
              <li key={b.id} className="flex items-start justify-between gap-3 px-4 py-3">
                <span className="min-w-0">
                  <span className="m-body block text-ink">{o.name}</span>
                  <span className="m-micro block text-ink-3">
                    {fmtDayLong(o.starts_at, ctx.timeZone)} · {fmtTime(o.starts_at, ctx.timeZone)}
                    {o.instructors?.display_name ? ` · ${o.instructors.display_name}` : ""}
                  </span>
                </span>
                <span className="m-micro shrink-0 font-semibold" style={{ color }}>{out.label}</span>
              </li>
            );
          })}
        </ul>
      )}
    </MemberShell>
  );
}
