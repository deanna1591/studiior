import Link from "next/link";
import { fmtDayLong } from "@/lib/time";
import { formatMoney } from "@/lib/plans";

export type ReservationDue = {
  occurrence_id: string; booking_id: string; class_name: string;
  starts_at: string; fee_cents: number;
};

/**
 * Decision 103: the existing-booking due notice. A free booking made before the
 * studio turned the fee on now needs the reservation fee, or the spot is released
 * at the cut-off. Shown on Home and the class page with Pay / Cancel.
 */
export default function ReservationDueNotice({
  dues, currency, timeZone,
}: { dues: ReservationDue[]; currency: string; timeZone: string }) {
  if (!dues.length) return null;
  return (
    <section aria-label="Reservation fee due" className="mb-5 space-y-3">
      {dues.map((d) => {
        const feeLabel = formatMoney(d.fee_cents, currency);
        return (
          <div key={d.booking_id}
               className="rounded-2xl px-3.5 py-3"
               style={{ background: "var(--coral-tint)", color: "var(--ink)",
                        boxShadow: "0 1px 3px rgb(26 21 18 / 0.06)" }}>
            <p className="text-[14px] font-semibold leading-5">
              A {feeLabel} reservation fee now holds your free class on {fmtDayLong(d.starts_at, timeZone)}.
            </p>
            <p className="mt-1 text-[12.5px] leading-[18px] text-ink-2">
              This is a reservation fee, not a charge for the class. Show up and the {feeLabel} is
              credited back to your account to use on class packages or merchandise. If you don&rsquo;t
              show up or cancel late, the fee is not refunded.
            </p>
            <div className="mt-3 flex items-center gap-3">
              <Link href={`/reserve/${d.occurrence_id}`}
                    className="m-press rounded-full px-3.5 py-2 text-[13px] font-semibold"
                    style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
                Pay {feeLabel} to keep my spot
              </Link>
              <Link href={`/class/${d.occurrence_id}`} className="text-[13px] text-ink-2 underline underline-offset-4">
                Cancel my booking
              </Link>
            </div>
          </div>
        );
      })}
    </section>
  );
}
