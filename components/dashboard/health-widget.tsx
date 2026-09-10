import Link from "next/link";
import { bandOf, HealthChip } from "@/components/health-band";
import type { HealthBlock } from "@/lib/dashboard";
import { Block, BlockEmpty } from "./block";

/**
 * 4.8. Member health, as bands with counts.
 *
 * NAMING — THE BIBLE AND DECISION 14 DISAGREE, AND DECISION 14 WINS.
 *
 * Ch. 4.8 lists four categories: Thriving, Drifting, At Risk, Critical.
 * Decision 14 settled five: healthy, drifting, at_risk, new,
 * insufficient_history. The decision log is canonical over the Bible for
 * settled decisions, and on the substance it is also right twice over:
 *
 *  - "Critical" is a fifth severity below At Risk, and Decision 14's bands
 *    are defined by WHICH SIGNALS FIRE, not by a depth of concern. There is no
 *    rule that would separate critical from at-risk, so the category would
 *    have to be invented at render time — which is a number the screen made
 *    up, in the one widget whose whole argument is that it does not do that.
 *  - The Bible has no state for a member the signals cannot speak about yet.
 *    Decision 14 has two, deliberately: `new` is a member with a clock running
 *    on them and `insufficient_history` is the absence of a verdict. Both used
 *    to render as "Too early" and it was the same mistake in miniature.
 *
 * "Thriving" against "Healthy" is a wording change and Decision 14's word is
 * the one already on the member screen, the list and the chips. Two names for
 * one band across four surfaces is worse than either name.
 */
export default function HealthWidget({ h, error }: { h: HealthBlock | null; error?: string | null }) {
  return (
    <Block
      title="Member health"
      hint={h?.state === "ok" ? `${h.banded} of ${h.total} members` : undefined}
      right={
        h?.state === "ok" ? (
          <Link href="/members" className="text-[12px] leading-4 text-lime-text underline underline-offset-4 hover:text-lime-text2">
            All members
          </Link>
        ) : null
      }
      error={error}
    >
      {!h ? null : h.state === "empty" ? (
        <BlockEmpty cta={{ href: "/members/new", label: "Add a member" }}>{h.empty_hint}</BlockEmpty>
      ) : h.state === "not_computed" ? (
        // NOT A CLEAN BILL OF HEALTH. Decision 14 is explicit that absence of
        // evidence is not evidence, and five zeros here would read as "nobody
        // is at risk" for a question nobody has asked yet.
        <BlockEmpty>{h.not_computed_hint}</BlockEmpty>
      ) : (
        <>
          <ul className="space-y-1">
            {h.bands.map((b) => (
              <li key={b.band}>
                <Link
                  href={b.href}
                  className="flex items-center justify-between rounded-lg px-2 py-2 hover:bg-paper"
                >
                  <HealthChip band={bandOf(b.band)} />
                  <span className="num text-[18px] leading-6 text-ink">{b.count}</span>
                </Link>
              </li>
            ))}
          </ul>
          {h.not_computed > 0 && (
            <p className="mt-2 px-2 text-[11px] leading-4 text-ink-3">
              <span className="num">{h.not_computed}</span>{" "}
              {h.not_computed === 1 ? "member has" : "members have"} no band yet — they
              are worked out overnight.
            </p>
          )}
        </>
      )}
    </Block>
  );
}
