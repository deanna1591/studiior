import Link from "next/link";
import { money, type ActivityBlock } from "@/lib/dashboard";
import { Block, BlockEmpty } from "./block";

/**
 * 4.9. Everything happening, newest first — read from timeline_events, which
 * is already the one derived record of what happens to a member (migration
 * 021, rebuilt by 059). Nothing is derived a second time here.
 *
 * A TIMELINE TITLE IS A NOUN FOR SOME TYPES AND A PHRASE FOR OTHERS, and the
 * first version of this treated them alike. `attended` titles itself with the
 * class; `payment` titles itself with its STATUS — 'Paid', 'Payment failed' —
 * and puts what was bought in `description` with the amount in `metadata`. So
 * "Deanna Sallao paid for Paid": a verb glued to a status, with a plan name
 * and a sum of money sitting unread in the same row.
 *
 * Each type composes its own line now, from the fields that type actually
 * fills in.
 *
 * `booked` is deliberately not in that table — it would tell every attended
 * class twice and every cancelled one twice — so this feed is what HAPPENED
 * rather than what was arranged. Said in the footnote, because a feed missing
 * the most frequent event in the product looks broken otherwise.
 */
type Item = ActivityBlock["items"][number];

/** "Joined the studio" -> "joined the studio". Only the first letter, so
 *  "Started on Unlimited Monthly" keeps the plan's own capitals. */
const lead = (s: string) => (s ? s.charAt(0).toLowerCase() + s.slice(1) : s);

function Line({ i }: { i: Item }) {
  const amount =
    i.amount_cents != null && i.currency ? money(i.amount_cents, i.currency) : null;

  if (i.type === "attended") {
    return (
      <>
        <span className="text-ink-2">came to </span>
        {i.title}
      </>
    );
  }

  if (i.type === "payment") {
    // A succeeded payment is the one that reads as an action. The rest keep
    // their own phrase, because "Deanna paid for Payment failed" is the bug
    // this function exists to stop repeating in a new shape.
    if (i.payment_status === "succeeded") {
      return (
        <>
          <span className="text-ink-2">paid </span>
          <span className="num">{amount}</span>
          {i.description && (
            <>
              <span className="text-ink-2"> for </span>
              {i.description}
            </>
          )}
        </>
      );
    }
    return (
      <>
        <span className="text-ink-2">— {lead(i.title)}</span>
        {amount && <>, <span className="num">{amount}</span></>}
        {i.description && <span className="text-ink-2"> for {i.description}</span>}
      </>
    );
  }

  return (
    <>
      <span className="text-ink-2">{lead(i.title)}</span>
      {i.description && <span className="text-ink-3"> · {i.description}</span>}
    </>
  );
}

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
                    <Line i={i} />
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
