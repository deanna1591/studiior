import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";

export const dynamic = "force-dynamic";

type Milestones = {
  total: number; next_target: number | null; to_go: number | null;
  ladder: { target: number; earned: boolean }[];
};

/**
 * Milestones, LEADING with the next one — the number, how close, what it takes.
 * Earned ones sit below as a quiet record. No fine print (Decision 10: personal,
 * no ranking; a reward's conditions are the studio's copy on the reward, not
 * legal text stapled here).
 */
export default async function MilestonesPage() {
  const { ctx, supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } =
    await memberScreen();

  const { data } = await supabase.rpc("member_milestones", { p_studio_id: ctx.studioId });
  const m = data as unknown as Milestones | null;
  const total = m?.total ?? 0;
  const next = m?.next_target ?? null;
  const toGo = m?.to_go ?? null;
  const ladder = m?.ladder ?? [];

  // The bar runs from the last milestone passed to the next one.
  const prev = ladder.filter((r) => r.earned).map((r) => r.target).reduce((a, b) => Math.max(a, b), 0);
  const pct = next ? Math.min(100, Math.round(((total - prev) / (next - prev)) * 100)) : 100;
  const earned = ladder.filter((r) => r.earned);
  const locked = ladder.filter((r) => !r.earned);

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href="/" className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Home
      </Link>
      <h1 className="m-title mb-4 text-ink">Milestones</h1>

      {/* The lead: the next target and how close. */}
      <section className="m-card p-5">
        {next ? (
          <>
            <p className="m-sub text-ink-2">Next milestone</p>
            <p className="num mt-1 text-[40px] font-bold leading-[44px] text-ink">{next}
              <span className="m-sub font-medium text-ink-3"> classes</span></p>
            <p className="m-body mt-1 text-ink">
              <span className="num font-semibold">{toGo}</span> to go — you are at{" "}
              <span className="num font-semibold">{total}</span>.
            </p>
            <div className="mt-3 h-2.5 w-full overflow-hidden rounded-full" style={{ background: "var(--accent-chip)" }}>
              <div className="h-full rounded-full" style={{ width: `${pct}%`, background: "var(--accent-solid)" }} />
            </div>
          </>
        ) : (
          <>
            <p className="num text-[40px] font-bold leading-[44px] text-ink">{total}</p>
            <p className="m-body mt-1 text-ink">classes, and every milestone behind you. Remarkable.</p>
          </>
        )}
      </section>

      {earned.length > 0 && (
        <section className="mt-6">
          <h2 className="section-label text-ink-2">Earned</h2>
          <div className="mt-3 flex flex-wrap gap-3">
            {earned.map((r) => (
              <span key={r.target}
                    className="flex h-16 w-16 flex-col items-center justify-center rounded-2xl"
                    style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
                <span className="num text-[18px] font-bold leading-5">{r.target}</span>
                <span className="text-[9px] font-semibold uppercase tracking-wide opacity-80">classes</span>
              </span>
            ))}
          </div>
        </section>
      )}

      {locked.length > 0 && (
        <section className="mt-6">
          <h2 className="section-label text-ink-2">Still to come</h2>
          <div className="mt-3 flex flex-wrap gap-3">
            {locked.map((r) => (
              <span key={r.target}
                    className="flex h-16 w-16 flex-col items-center justify-center rounded-2xl border border-line-2"
                    style={{ color: "var(--ink-3)" }}>
                <span className="num text-[18px] font-bold leading-5">{r.target}</span>
                <span className="text-[9px] font-semibold uppercase tracking-wide">classes</span>
              </span>
            ))}
          </div>
        </section>
      )}
    </MemberShell>
  );
}
