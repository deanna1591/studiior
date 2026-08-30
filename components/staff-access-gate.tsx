import { redirect } from "next/navigation";
import type { StaffAccess } from "@/lib/auth";
import { Shell } from "@/components/ui";

/**
 * What to do with a request that is not active staff of a studio.
 *
 *   anonymous       -> sign in
 *   platform admin  -> /admin, which is the screen they actually want; they
 *                      run the platform and are staff of no studio
 *   anyone else     -> an explanation, rendered where they are
 *
 * That last case is deliberately not a redirect. Sending them to /login is what
 * produced the loop, and sending them anywhere else would just hide the reason
 * they cannot get in.
 */
export default function StaffAccessGate({ access }: { access: StaffAccess }) {
  if (access.kind === "anonymous") redirect("/login");
  if (access.kind === "staff") return null;
  if (access.isPlatformAdmin) redirect("/admin");

  return (
    <Shell title="No studio access" subtitle={access.email}>
      <div className="max-w-lg space-y-3 text-sm leading-relaxed text-ink">
        <p>
          You are signed in, but this account is not staff at any studio, so
          there is nothing here for it to show.
        </p>
        <p>
          That usually means the invite was sent to a different address than the
          one you signed in with, or your access was removed. Whoever owns the
          studio can add you again from their staff settings.
        </p>
        <p className="text-ink-3">
          Signed in as <span className="font-medium">{access.email}</span>.{" "}
          <a href="/login" className="underline underline-offset-4">
            Sign in as someone else
          </a>
          .
        </p>
      </div>
    </Shell>
  );
}
