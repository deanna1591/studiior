/**
 * A member's photograph on a staff screen.
 *
 * Deliberately not the member app's Avatar: that one is themed with the
 * studio's accent, and the staff app is not themed (CLAUDE.md — theming both
 * would mean every support conversation starts with "what does yours look
 * like"). Same idea, Studiior's own palette.
 */
export default function StaffAvatar({
  name, url, size = 28,
}: {
  name: string;
  url: string | null;
  size?: number;
}) {
  const initials = name.split(/\s+/).filter(Boolean).slice(0, 2)
    .map((w) => w[0]?.toUpperCase() ?? "").join("");

  if (url) {
    return (
      // eslint-disable-next-line @next/next/no-img-element
      <img src={url} alt="" aria-hidden width={size} height={size}
           style={{ width: size, height: size }}
           className="shrink-0 rounded-full border border-line object-cover" />
    );
  }
  return (
    <span aria-hidden style={{ width: size, height: size, fontSize: Math.round(size * 0.36) }}
          className="flex shrink-0 items-center justify-center rounded-full bg-lime-tint font-semibold text-lime-text">
      {initials || "?"}
    </span>
  );
}
