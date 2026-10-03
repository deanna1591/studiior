import Link from "next/link";
import type { TierSuggestion } from "@/lib/dashboard";
import { Block, BlockEmpty } from "./block";

/**
 * Decision 56 — Decision 22's core minimum, read backwards.
 *
 * A core class that keeps missing its minimum is paying a guarantee it is not
 * earning; a flex class that always clears the minimum is under-paying its
 * instructor relative to a core one. The sentence is the whole suggestion —
 * nothing changes automatically and no email is sent. Each row links to the
 * series page, where the owner changes the tier themselves.
 *
 * The block is rendered only when the studio uses tiers at all (guarantees or
 * flex on); the caller decides that, because zero rows here means "no class
 * qualifies yet", which is a real thing to say, not a reason to hide.
 */
export default function TierSuggestions({
  rows, error,
}: { rows: TierSuggestion[]; error?: string | null }) {
  return (
    <Block title="Tier suggestions" error={error}>
      {rows.length === 0 ? (
        <BlockEmpty>Not enough classes yet to suggest tier changes.</BlockEmpty>
      ) : (
        <ul className="divide-y divide-line">
          {rows.map((s) => (
            <li key={s.series_id} className="flex items-baseline gap-3 px-1 py-2">
              <span className="min-w-0 flex-1 text-[13px] leading-[19px] text-ink">
                {s.sentence}
              </span>
              <Link
                href={`/series/${s.series_id}`}
                className="shrink-0 text-[12px] leading-4 text-lime-text underline underline-offset-4 hover:text-lime-text2"
              >
                Open class
              </Link>
            </li>
          ))}
        </ul>
      )}
    </Block>
  );
}
