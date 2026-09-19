import Link from "next/link";

/**
 * Decision 26/34 — a member (or a brought guest) holds a place confirmed only
 * once they sign the studio's waiver. Shown on Home until they do; it links to
 * the signing screen, where the full waiver is shown and a signature captured
 * (Decision 34 — the old inline one-tap button signed nothing they had read).
 *
 * Three states: the studio requires a waiver but has published NONE (nothing to
 * sign — say so rather than send them to an empty screen); a first sign; and a
 * re-sign when the current version requires it.
 */
export default function WaiverBanner({ published, resign }: { published: boolean; resign: boolean }) {
  if (!published) {
    return (
      <div className="m-card mb-4 p-4">
        <p className="m-name text-ink">Waiver on the way</p>
        <p className="m-sub mt-1 text-ink-2">
          This studio hasn&rsquo;t published its waiver yet. You&rsquo;ll be able to
          sign it here as soon as they do — have a word with the studio if you have a
          class coming up.
        </p>
      </div>
    );
  }
  return (
    <div className="m-card mb-4 p-4">
      <p className="m-name text-ink">
        {resign ? "The studio waiver has been updated" : "One thing before your class"}
      </p>
      <p className="m-sub mt-1 text-ink-2">
        {resign
          ? "Please read and sign the current version to keep booking."
          : "Please read and sign the studio waiver. Your place is confirmed once you have — the front desk can’t check you in without it."}
      </p>
      <Link href="/waiver"
            className="m-tap m-press mt-2 inline-flex rounded-full px-4 py-2.5 text-[13px] font-bold"
            style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
        {resign ? "Read & re-sign the waiver" : "Read & sign the waiver"}
      </Link>
    </div>
  );
}
