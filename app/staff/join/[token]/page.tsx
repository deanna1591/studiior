import { createClient } from "@/lib/supabase/server";
import JoinForm from "./form";

export const dynamic = "force-dynamic";

/**
 * Decision 70 — the staff claim page (manager / front desk). Public, like the
 * owner invite page; the token in the URL is the credential. Reuses the
 * generalised instructor_invite_preview / claim_instructor_account pair.
 */
export default async function JoinPage({ params }: { params: { token: string } }) {
  const supabase = createClient();
  const { data } = await supabase.rpc("instructor_invite_preview", { p_token: params.token });
  const preview = data as unknown as {
    state: string; role?: string; studio_name?: string; email?: string;
  } | null;
  const state = preview?.state ?? "invalid";

  if (state !== "ok") {
    const message =
      state === "expired" ? "This invite has expired. Ask your studio for a fresh link."
      : state === "used" ? "This invite has already been used. If that was you, sign in instead."
      : "This invite link is not valid. Check you copied the whole link, or ask for a new one.";
    return (
      <div className="mx-auto max-w-md px-5 py-16">
        <h1 className="text-xl font-semibold tracking-tight">
          {state === "used" ? "Already accepted" : state === "expired" ? "Invite expired" : "Invite not found"}
        </h1>
        <p className="mt-3 text-sm leading-relaxed text-ink-2">{message}</p>
        {state === "used" && <p className="mt-4 text-sm"><a href="/login" className="underline underline-offset-4">Go to sign in</a></p>}
      </div>
    );
  }

  const roleLabel = preview!.role === "manager" ? "a manager" : "front desk";
  return (
    <div className="mx-auto max-w-md px-5 py-16">
      <h1 className="text-xl font-semibold tracking-tight">Join {preview!.studio_name}</h1>
      <p className="mb-6 mt-1 text-sm text-ink-2">
        You have been invited as {roleLabel}. Choose a password and we will create your account.
      </p>
      <JoinForm token={params.token} email={preview!.email ?? ""} />
    </div>
  );
}
