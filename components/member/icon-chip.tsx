import { Icon, type IconName } from "./icons";

/**
 * An icon on a tinted square.
 *
 * Used everywhere an icon appears next to text — class metadata, the stat row,
 * the profile screen. A bare 16px glyph beside a 13px line is a mark on a page;
 * the same glyph on a filled square is a component, and a column of them lines
 * up on a grid instead of drifting with the text.
 *
 * The fill is --accent-chip, the studio's accent at 14%, so these are warm in a
 * terracotta studio and cool in a navy one. The glyph takes --lime-text, the
 * ramp's readable accent, which was measured against the surface the chip sits
 * on rather than against the chip — 14% is close enough to the surface that the
 * difference is under a tenth of a point, and the alternative is a second ramp.
 */
export default function IconChip({
  name, size = 32, icon = 16, tone = "accent",
}: {
  name: IconName;
  /** The square. 32 in lists, 40 in the stat row. */
  size?: number;
  icon?: number;
  tone?: "accent" | "quiet";
}) {
  return (
    <span
      className="m-icon-chip"
      style={{
        width: size,
        height: size,
        background: tone === "quiet" ? "var(--paper)" : "var(--accent-chip)",
        color: tone === "quiet" ? "var(--ink-3)" : "var(--lime-text)",
      }}
    >
      <Icon name={name} size={icon} />
    </span>
  );
}
