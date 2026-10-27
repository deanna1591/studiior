/**
 * The object path inside a PUBLIC Supabase bucket, parsed from the public URL
 * we stored in a column (studios.logo_url, class_types.image_url, …). Returns
 * null for a blank or external URL — so "best-effort delete the previous
 * object" only ever touches our own bucket. Mirrors the `pathInBucket` helpers
 * already inline in the instructor and shop upload actions.
 */
export function objectPathFromPublicUrl(url: string | null | undefined, bucket: string): string | null {
  if (!url) return null;
  const marker = `/${bucket}/`;
  const i = url.indexOf(marker);
  return i === -1 ? null : url.slice(i + marker.length);
}
