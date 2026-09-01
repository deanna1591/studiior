import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";

type Client = SupabaseClient<Database>;

/**
 * Member photographs are private and read through signed URLs.
 *
 * `member-avatars` is not a public bucket, unlike `studio-branding`: a logo and
 * a class photograph are things a studio publishes, and a member's face is not.
 * `members.avatar_url` therefore holds the OBJECT PATH — `<member id>/<file>` —
 * not a URL, and every render signs it. Instructor avatars are ordinary public
 * URLs and do not come through here; the studio publishes those deliberately.
 *
 * An hour is long enough for a page and short enough that a URL pasted into a
 * chat stops working. A failure returns null and the caller falls back to
 * initials, because a broken image is worse than no image.
 */
const BUCKET = "member-avatars";
const TTL_SECONDS = 3600;

export async function signAvatar(supabase: Client, path: string | null | undefined) {
  if (!path) return null;
  const { data } = await supabase.storage.from(BUCKET).createSignedUrl(path, TTL_SECONDS);
  return data?.signedUrl ?? null;
}

/**
 * One round trip for a whole roster. Signing twenty photographs one at a time
 * is twenty requests on a screen that already has work to do.
 */
export async function signAvatars(supabase: Client, paths: (string | null | undefined)[]) {
  const wanted = [...new Set(paths.filter((p): p is string => !!p))];
  if (wanted.length === 0) return new Map<string, string>();

  const { data } = await supabase.storage.from(BUCKET).createSignedUrls(wanted, TTL_SECONDS);
  const out = new Map<string, string>();
  for (const row of data ?? []) {
    if (row.signedUrl && row.path) out.set(row.path, row.signedUrl);
  }
  return out;
}
