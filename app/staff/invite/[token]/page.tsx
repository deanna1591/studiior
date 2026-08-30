import { createClient } from "@/lib/supabase/server";
import AcceptForm from "./form";

export const dynamic = "force-dynamic";

/**
 * Step 1 of the wizard, and the only page in the app reachable without an
 * account. The token in the URL is the credential; studio_invite_preview()
 * turns it into a state anon may see, so an expired or spent link says so
 * rather than failing on submit.
 */
export default async function InvitePage({ params }: { params: { token: string } }) {
  const supabase = createClient();
  const { data } = await supabase.rpc("studio_invite_preview", { p_token: params.token });

  const preview = data as unknown as {
    studio_name: string | null; email: string | null;
    expires_at: string | null; state: string;
  } | null;

  const state = preview?.state ?? "invalid";

  if (state !== "valid") {
    const message =
      state === "expired"
        ? "This invite has expired. Ask your Studiior contact for a fresh link."
        : state === "used"
          ? "This invite has already been used. If that was you, sign in instead."
          : "This invite link is not valid. Check you copied the whole link, or ask for a new one.";
    return (
      <div className="mx-auto max-w-md px-5 py-16">
        <h1 className="text-xl font-semibold tracking-tight">
          {state === "used" ? "Already accepted" : state === "expired" ? "Invite expired" : "Invite not found"}
        </h1>
        <p className="mt-3 text-sm leading-relaxed text-stone-600">{message}</p>
        {state === "used" && (
          <p className="mt-4 text-sm">
            <a href="/login" className="underline underline-offset-4">Go to sign in</a>
          </p>
        )}
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-md px-5 py-16">
      <p className="text-xs font-semibold uppercase tracking-wide text-stone-500">Step 1 of 3</p>
      <h1 className="mt-1 text-xl font-semibold tracking-tight">
        Set up {preview!.studio_name}
      </h1>
      <p className="mb-6 mt-1 text-sm text-stone-600">
        You have been invited as the owner. Choose a password and we will create
        your account.
      </p>
      <AcceptForm token={params.token} email={preview!.email ?? ""} />
    </div>
  );
}
