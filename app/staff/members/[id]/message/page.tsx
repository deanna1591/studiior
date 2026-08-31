import { notFound } from "next/navigation";
import { isDeskUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Empty, NavLink } from "@/components/ui";
import { HealthBand, bandOf } from "@/components/health-band";
import ComposeForm from "./compose-form";

export const dynamic = "force-dynamic";

/**
 * Compose a message to one member.
 *
 * The band sits above the draft because it is the reason the draft says what
 * it says. Someone who disagrees with the reason should be able to see it and
 * rewrite the note, rather than sending a stock line about a member they know
 * better than the score does.
 */
export default async function ComposeMessage({ params }: { params: { id: string } }) {
  const screen = await staffScreen("/members");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  const { data: m } = await supabase
    .from("members")
    .select("id, first_name, last_name, email, health_band, health_reason, marketing_opt_in")
    .eq("id", params.id)
    .maybeSingle();
  if (!m) notFound();

  // Permissions §12. The RPC below asks the same question again in SQL, so
  // reaching this page another way gets a refusal rather than a form.
  if (!isDeskUp(ctx.role)) {
    return (
      <AppShell {...shell} title="Message">
        <Empty>
          Messaging members is for owners, managers and front desk. You are
          signed in as {ctx.role.replace("_", " ")}.
        </Empty>
      </AppShell>
    );
  }

  const { data: draft, error } = await supabase.rpc("message_draft_for", {
    p_member_id: params.id,
  });

  if (error || !draft) {
    return (
      <AppShell {...shell} title="Message">
        <Empty>
          {error?.message ?? "That draft could not be composed."}
        </Empty>
      </AppShell>
    );
  }

  const d = draft as {
    template_key: string; subject: string; body: string;
    marketing_opt_in: boolean; transactional: boolean;
  };

  const name = `${m.first_name} ${m.last_name}`;

  return (
    <AppShell
      {...shell}
      title={`Message ${m.first_name}`}
      actions={<NavLink href={`/members/${m.id}`}>Back to {m.first_name}</NavLink>}
    >
      <div className="mb-6 max-w-[68ch]">
        <HealthBand band={bandOf(m.health_band)} reason={m.health_reason} size="hero" />
      </div>

      {/* Only 20 of this studio's members have opted into marketing. A card
          that failed is something they need to know either way; a note saying
          we have missed them is not, and the owner is the one who gets to
          weigh that. Stated, not enforced — blocking it would be guessing at
          the law on the studio's behalf. */}
      {!d.marketing_opt_in && !d.transactional && (
        <p className="mb-6 max-w-[68ch] border-l-[3px] border-line-2 bg-paper px-3 py-2 text-[12px] leading-[17px] text-ink-2">
          {m.first_name} has not opted in to marketing email. A note about a
          missed class is a judgement call — a failed payment would not be.
        </p>
      )}

      <ComposeForm
        memberId={m.id}
        memberName={name}
        email={m.email}
        subject={d.subject}
        body={d.body}
        templateKey={d.template_key}
        backHref={`/members/${m.id}`}
      />
    </AppShell>
  );
}
