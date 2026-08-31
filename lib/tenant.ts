import { headers } from "next/headers";

/**
 * Which app is being served, decided by hostname in middleware.
 *
 *   app.studiior.com    / localhost:3000        -> staff
 *   {slug}.studiior.app / {slug}.lvh.me:3000    -> member PWA
 *
 * lvh.me resolves to 127.0.0.1 with wildcard subdomains, which is what makes
 * subdomain routing testable locally without editing /etc/hosts.
 */
export const APP_HEADER = "x-studiior-app";
export const SLUG_HEADER = "x-studiior-slug";

export type AppKind = "staff" | "member";

export function resolveHost(host: string): { app: AppKind; slug?: string } {
  const hostname = host.split(":")[0].toLowerCase();
  const memberBase = (process.env.NEXT_PUBLIC_MEMBER_DOMAIN ?? "lvh.me:3000")
    .split(":")[0]
    .toLowerCase();

  // Bare localhost / app.* is the staff app.
  if (hostname === "localhost" || hostname === "127.0.0.1") return { app: "staff" };
  if (hostname.startsWith("app.")) return { app: "staff" };

  // {slug}.studiior.app in production; locally {slug}.lvh.me or
  // {slug}.localhost — both resolve to 127.0.0.1 with no /etc/hosts edit, and
  // some browsers are happier with one than the other.
  const memberBases = [memberBase, "lvh.me", "localhost", "studiior.app"];
  if (memberBases.some((b) => hostname.endsWith(`.${b}`))) {
    const slug = hostname.split(".")[0];
    if (slug && slug !== "www" && slug !== "app") return { app: "member", slug };
  }

  return { app: "staff" };
}

/** Slug for the current member request, set by middleware. */
export function currentSlug(): string | null {
  return headers().get(SLUG_HEADER);
}

/**
 * Where a member's app lives, for building links from the staff side.
 *
 * Not "the staff host with app. stripped": the two apps are on different
 * domains in production — app.studiior.com and {slug}.studiior.app — so
 * deriving one from the other is only ever right by accident.
 */
export function memberOrigin(slug: string): string {
  const base = process.env.NEXT_PUBLIC_MEMBER_DOMAIN ?? "localhost:3000";
  const scheme = base.includes("localhost") || base.includes("lvh.me") ? "http" : "https";
  return `${scheme}://${slug}.${base}`;
}
