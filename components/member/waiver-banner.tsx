import Link from "next/link";

/**
 * Decision 26/34 — a member (or a brought guest) holds a place confirmed only
 * once they sign the studio's waiver. Shown on Home until they do; it links to
 * the signing screen, where the full waiver is shown and a signature captured
 * (Decision 34 — the old inline one-tap button signed nothing they had read).
 */
export default function WaiverBanner({ memberId: _memberId }: { memberId: string }) {
  return (
    <div className="m-card mb-4 p-4">
      <p className="m-name text-ink">One thing before your class</p>
      <p className="m-sub mt-1 text-ink-2">
        Please read and sign the studio waiver. Your place is confirmed once you
        have — the front desk can&rsquo;t check you in without it.
      </p>
      <Link href="/waiver"
            className="m-tap m-press mt-2 inline-flex rounded-full px-4 py-2.5 text-[13px] font-bold"
            style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
        Read &amp; sign the waiver
      </Link>
    </div>
  );
}
