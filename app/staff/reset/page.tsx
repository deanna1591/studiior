import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import ResetForm from "./form";

export const dynamic = "force-dynamic";

/**
 * Decision 84 — staff set-a-new-password. Reached only from a recovery link,
 * which /auth/callback turned into a recovery session; no session means the
 * link was bad or expired (> 1 hour), so this points at a fresh request rather
 * than an input that cannot work.
 */
export default async function StaffReset() {
  const supabase = createClient();
  const { data: claims } = await supabase.auth.getClaims();
  const hasSession = !!claims?.claims?.sub;

  return (
    <div className="mx-auto max-w-sm px-5 py-16">
      {hasSession ? (
        <>
          <h1 className="text-xl font-semibold tracking-tight">Set a new password</h1>
          <p className="mb-6 mt-1 text-sm text-ink-3">Then sign in with it.</p>
          <ResetForm />
        </>
      ) : (
        <>
          <h1 className="text-xl font-semibold tracking-tight">This link has expired</h1>
          <p className="mb-6 mt-1 text-sm text-ink-3">
            Reset links last an hour. Ask for a fresh one and try again.
          </p>
          <Link href="/forgot" className="text-sm text-ink underline underline-offset-4">
            Send a new reset link
          </Link>
        </>
      )}
    </div>
  );
}
