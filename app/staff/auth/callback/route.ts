import { NextResponse, type NextRequest } from "next/server";
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import type { Database } from "@/lib/database.types";
import { safeNext } from "@/lib/auth-redirect";

// Decision 84: the staff auth callback. Only the password-reset flow reaches it
// (staff accounts are created by invite, not self-signup), so it is simpler
// than the member callback — no studio slug, no claim. It establishes the
// recovery session from ?code= (exchangeCodeForSession) or ?token_hash=&type=
// (verifyOtp), then redirects to the safe `next` (/reset), which decides what
// to show from whether the session was set. A failed exchange sets no session
// and /reset shows "expired", so this holds for the failed case too.
//
// Middleware rewrites /auth/callback -> /staff/auth/callback without the
// session refresh, so this handler owns the cookie write (a Route Handler can).
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

  if (code) {
    await supabase.auth.exchangeCodeForSession(code);
  } else if (tokenHash && type) {
    await supabase.auth.verifyOtp({
      type: type as "signup" | "recovery" | "email" | "email_change" | "invite" | "magiclink",
      token_hash: tokenHash,
    });
  }

  // Build the redirect from the request's OWN Host header (the staff host),
  // never url.origin — behind the middleware rewrite and bound to localhost in
  // dev, url.origin is the server origin, not app.studiior.com.
  const host = request.headers.get("host") ?? url.host;
  const hostname = host.split(":")[0].toLowerCase();
  const local = hostname === "localhost" || hostname === "127.0.0.1";
  const base = `${local ? "http" : "https"}://${host}`;

  return NextResponse.redirect(new URL(next, base));
}
