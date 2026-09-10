import Link from "next/link";
import type { ActivityBlock } from "@/lib/dashboard";
import { Block, BlockEmpty } from "./block";

/**
 * A verb only where the timeline's own title is a NOUN.
 *
 * migration 021 writes `attended` and `payment` with the class or the thing
 * paid for as the title, and everything else with a complete phrase —
 * "Cancelled late", "Joined the studio". Putting a verb in front of those
 * gives "Alena cancelled Cancelled late", which is how it read the first time.
 */
const VERB: Record<string, string> = {
  attended: "came to",
  payment: "paid for",
};

/**
 * 4.9. Everything happening, newest first — read from timeline_events, which
 * is already the one derived record of what happens to a member (migration
 * 021, rebuilt by 059). Nothing is derived a second time here: a second
 * derivation would disagree with the member's own journey the first time
 * either of them changed.
 *
 * `booked` IS DELIBERATELY NOT IN THAT TABLE — it tells every attended class
 * twice and every cancelled one twice — so this feed is what happened rather
 * than what was arranged. Said in the footnote, because a feed missing the
 * most frequent event in the product looks broken otherwise.
 */
export default function ActivityFeed({
  a, timeZone, error,
}: { a: ActivityBlock | null; timeZone: string; error?: string | null }) {
  const when = (iso: string) =>
    new Intl.DateTimeFormat("en-GB", {
      timeZone, day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hour12: false,
    }).format(new Date(iso));

  return (
    <Block title="Recent activity" error={error}>
      {!a ? null : a.state === "empty" ? (
        <BlockEmpty>{a.empty_hint}</BlockEmpty>
      ) : (
        <>
          <ul className="divide-y divide-line">
            {a.items.map((i) => (
              <li key={i.id}>
                <Link href={i.href} className="flex items-baseline gap-3 rounded px-1 py-2 hover:bg-paper">
                  <span className="min-w-0 flex-1 text-[13px] leading-[19px] text-ink">
                    <span className="font-medium">{i.member_name}</span>{" "}
                    {VERB[i.type] && <span className="text-ink-2">{VERB[i.type]} </span>}
                    <span className={VERB[i.type] ? "" : "text-ink-2"}>{i.title}</span>
                  </span>
                  <span className="num shrink-0 text-[11px] leading-4 text-ink-3">
                    {when(i.occurred_at)}
                  </span>
                </Link>
              </li>
            ))}
          </ul>
          <p className="mt-2 text-[11px] leading-4 text-ink-3">
            Visits, payments, membership changes and messages. Bookings are not
            listed — a booking shows up here when it is attended or cancelled.
          </p>
        </>
      )}
    </Block>
  );
}
