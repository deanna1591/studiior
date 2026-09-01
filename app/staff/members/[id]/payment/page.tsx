import { notFound } from "next/navigation";
import { AppShell, Empty, NavLink } from "@/components/ui";
import { staffScreen } from "@/lib/screen";
import PaymentForm from "./form";

export const dynamic = "force-dynamic";

/**
 * Record a payment against a member.
 *
 * Decision 16: this is how a studio takes money. Cash at the counter, a bank
 * transfer, GCash, a terminal — the product records what happened rather than
 * insisting on being the thing that happened.
 *
 * Front desk and above (§9 reads their "Payments" as taking payment). The
 * function enforces it; this decides what to offer.
 */
export default async function RecordPayment({ params }: { params: { id: string } }) {
  const screen = await staffScreen("/members");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  const [{ data: member }, { data: plans }, { data: unpaid }, { data: studio }] =
    await Promise.all([
      supabase.from("members").select("id, first_name, last_name").eq("id", params.id).maybeSingle(),
      supabase.from("membership_plans")
        .select("id, name, type, price_cents, currency")
        .eq("studio_id", ctx.studioId).eq("status", "active").order("sort_order"),
      // Classes they are in that nobody has been paid for — the common reason
      // somebody is standing at the desk with money in their hand.
      supabase.from("bookings")
        .select("id, status, class_occurrences(name, starts_at)")
        .eq("member_id", params.id)
        .in("status", ["booked", "pending_payment"])
        .order("booked_at", { ascending: false }).limit(10),
      supabase.from("studios").select("currency").eq("id", ctx.studioId).maybeSingle(),
    ]);

  if (!member) notFound();

  const name = `${member.first_name} ${member.last_name}`.trim();

  return (
    <AppShell {...shell} title={`Record a payment — ${name}`}
              actions={<NavLink href={`/members/${params.id}`}>Back to {member.first_name}</NavLink>}>
      {(plans ?? []).length === 0 ? (
        <Empty>
          There are no plans to sell yet. Add one on the plans screen first.
        </Empty>
      ) : (
        <PaymentForm
          memberId={params.id}
          currency={studio?.currency ?? "USD"}
          plans={(plans ?? []).map((p) => ({
            id: p.id, name: p.name, type: p.type,
            price_cents: p.price_cents, currency: p.currency,
          }))}
          bookings={(unpaid ?? []).map((b) => ({
            id: b.id,
            status: b.status,
            label: `${b.class_occurrences?.name ?? "Class"} — ${
              b.class_occurrences?.starts_at
                ? new Date(b.class_occurrences.starts_at).toLocaleDateString()
                : ""}`,
          }))}
        />
      )}
    </AppShell>
  );
}
