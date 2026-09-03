/**
 * An instructor's face, or their initials.
 *
 * `instructors.avatar_url` is nullable and no seeded instructor has one, which
 * is also true of a real studio on its first day. The fallback is therefore
 * the normal case, not the error case, and it is built to look deliberate:
 * initials on the accent's tint, in the accent's readable text colour. A grey
 * silhouette icon would say "missing" about a person who is simply new.
 */
export default function Avatar({
  name, url, size = 56,
}: {
  name: string;
  url: string | null;
  size?: number;
}) {
  const initials = name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0]?.toUpperCase() ?? "")
    .join("");

  if (url) {
    return (
      // eslint-disable-next-line @next/next/no-img-element
      <img
        src={url}
        alt={name}
        width={size}
        height={size}
        style={{ width: size, height: size }}
        className="shrink-0 rounded-full border border-line object-cover"
      />
    );
  }

  return (
    <span
      aria-hidden
      style={{
        width: size, height: size,
        // Ink on the chip, not accent-on-tint. The accent's text step is
        // derived against the surface and the wash; the tint is neither, and
        // the initial measured 3.88 on it.
        background: "var(--accent-chip)",
        color: "var(--ink)",
        fontSize: Math.round(size * 0.34),
      }}
      className="flex shrink-0 items-center justify-center rounded-full border border-line font-semibold"
    >
      {initials || "?"}
    </span>
  );
}
