import Link from "next/link";
import { staffScreen } from "@/lib/screen";
import { isManagerUp } from "@/lib/auth";
import { AppShell, Denied, Empty, Rows } from "@/components/ui";
import InviteRow from "./row";

export const dynamic = "force-dynamic";

type Row = {
  id: string; display_name: string; email: string | null;
  state: "signed_in" | "invited" | "invite_expired" | "no_email" | "never_asked";
  expires_at: string | null; invited_at: string | null;
};

/**
 * WHO CAN ACTUALLY SIGN IN.
 *
 * Every one of Reform Collective's six instructors had no staff row, so none
 * could sign in — and every instructor notification ever built was being
 * queued for somebody with no address. The cover flow reported them as
 * unreachable, which was honest and also meant the feature did nothing.
 *
 * Three states matter and the third is the one that could not previously be
 * known to exist: signed in, asked, and NEVER ASKED. Same gap migration 073
 * closed for members.
 */
export default async function InstructorAccess() {
  const screen = await staffScreen("/instructors/access");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return (
      <AppShell {...shell} title="Instructor access">
        <Denied what="Inviting instructors" role={ctx.role} />
      </AppShell>
    );
  }

  const { data, error } = await supabase.rpc("instructor_invite_status", {
    p_studio_id: ctx.studioId,
  });
  const rows = (data ?? []) as Row[];
  const noEmail = rows.filter((r) => r.state === "no_email");
  const signedIn = rows.filter((r) => r.state === "signed_in").length;

  return (
    <AppShell
      {...shell}
      title="Instructor access"
      actions={
        <Link href="/instructors" className="text-[13px] text-ink-3 underline underline-offset-4 hover:text-ink">
          Back to instructors
        </Link>
      }
    >
      <p className="mb-4 max-w-[72ch] text-[14px] leading-[21px] text-ink-2">
        An instructor who cannot sign in cannot be told anything either — every
        assignment, cover request, weekly confirmation and availability reminder
        needs an address to go to.{" "}
        <span className="text-ink">
          <span className="num">{signedIn}</span> of{" "}
          <span className="num">{rows.length}</span> can sign in.
        </span>
      </p>

      {error ? (
        <div className="max-w-[62ch] border-l-[3px] px-3.5 py-3"
             style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}>
          <p className="text-[13px] leading-[19px] text-ink">This could not be read.</p>
          <p className="num mt-2 text-[12px] leading-[17px] text-ink-2">{error.message}</p>
        </div>
      ) : rows.length === 0 ? (
        <Empty>No active instructors yet.</Empty>
      ) : (
        <Rows>
          {rows.map((r) => <InviteRow key={r.id} row={r} />)}
        </Rows>
      )}

      {noEmail.length > 0 && (
        <p className="mt-3 max-w-[72ch] text-[11px] leading-4 text-ink-3">
          <span className="num">{noEmail.length}</span>{" "}
          {noEmail.length === 1 ? "instructor has" : "instructors have"} no email
          address, so there is nowhere to send an invite. An instructor record
          carries no email of its own — it is set here, on the staff row the
          invite creates.
        </p>
      )}
    </AppShell>
  );
}
