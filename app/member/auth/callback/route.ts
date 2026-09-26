import { NextResponse, type NextRequest } from "next/server";
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import type { Database } from "@/lib/database.types";
import { safeNext } from "@/lib/auth-redirect";

// Decision 41: the per-studio auth callback. Supabase sends the member back
// here on THIS studio's own host (emailRedirectTo, built per request). It
// handles both shapes GoTrue may send — ?code= (PKCE / newer links,
// exchangeCodeForSession) and ?token_hash=&type= (older confirmation links,
// verifyOtp) — establishes the session with the @supabase/ssr cookie client
// (a Route Handler CAN write cookies, unlike a Server Component), then
// redirects to `next` ONLY if it is a relative path (open-redirect guard,
// shared safeNext). On any error it lands on the studio's own member login.
//
// The route lives in the member subtree so the middleware host rewrite reaches
// it ({slug}.studiior.app/auth/callback -> /member/auth/callback), and the
// middleware lets it through without a session (there is none yet).
export const dynamic = "force-dynamic";

export async function GET(request: NextRequest): Promise<NextResponse> {
  const url = new URL(request.url);
  const next = safeNext(url.searchParams.get("next"));
  const code = url.searchParams.get("code");
  const tokenHash = url.searchParams.get("token_hash");
  const type = url.searchParams.get("type");

  const store = cookies();
  const supabase = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => store.getAll(),
        setAll: (toSet) =>
          toSet.forEach(({ name, value, options }) => store.set(name, value, options)),
      },
    },
  );

  let failed = true;
  if (code) {
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    failed = !!error;
  } else if (tokenHash && type) {
    const { error } = await supabase.auth.verifyOtp({
      type: type as "signup" | "recovery" | "email" | "email_change" | "invite" | "magiclink",
      token_hash: tokenHash,
    });
    failed = !!error;
  }

  // Build the redirect from the request's OWN Host header, not url.origin:
  // behind the middleware rewrite (and bound to localhost in dev) url.origin is
  // the server origin, not the member subdomain — sending the member to
  // localhost/login is the very staff-login bug this fixes. The Host header is
  // the member host (middleware forwards it), so the destination and the error
  // page are both this studio's own screens.
  const host = request.headers.get("host") ?? url.host;
  const hostname = host.split(":")[0].toLowerCase();
  const local =
    hostname === "localhost" || hostname === "127.0.0.1" ||
    hostname === "lvh.me" || hostname.endsWith(".localhost") || hostname.endsWith(".lvh.me");
  const base = `${local ? "http" : "https"}://${host}`;

  if (failed) return NextResponse.redirect(new URL("/login?error=confirm", base));
  return NextResponse.redirect(new URL(next, base));
}
