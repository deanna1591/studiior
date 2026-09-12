"use client";

import { useTransition } from "react";
import { signOut } from "@/app/member/actions";

/**
 * Sign out and land in the RIGHT building.
 *
 * signOut() only clears the session — a server-action redirect() to a member
 * path renders the staff app (the redirect-follow loses the studio subdomain,
 * exactly the bug useAuthAction() exists for), so a signed-out member would
 * land on the staff login. This navigates with window.location.assign after
 * the session is cleared: a full-document load keeps the subdomain and re-runs
 * the host->app rewrite. `to` is the member-app door to land on — "/login" for
 * the member app, "/instructor/login" for the portal.
 */
export function SignOut({
  to, className, style, children,
}: {
  to: string;
  className?: string;
  style?: React.CSSProperties;
  children: React.ReactNode;
}) {
  const [pending, start] = useTransition();
  return (
    <button
      type="button"
      disabled={pending}
      className={className}
      style={style}
      onClick={() =>
        start(async () => {
          await signOut();
          window.location.assign(to);
        })
      }
    >
      {pending ? "Signing out…" : children}
    </button>
  );
}
