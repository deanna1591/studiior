// Decision 54 (+ guarantees/flex visibility) — the pure rule behind the small
// core/flex tag on an instructor-facing class row. Kept here as plain ESM so
// node --test exercises it with no bundler; components/instructor/class-tag.tsx
// renders it.
//
// The tag shows only the tier the studio actually RUNS. A tier whose switch is
// off behaves as "always" (runs regardless, Decision 110), so it earns no tag:
//   both off          → no tag
//   guarantees on only → core classes only (flex-tier → always → no tag)
//   flex on only       → flex classes only (core-tier → always → no tag)
//   both on            → core gets "core", flex gets the flex tag
// An "always" class never gets a tag. The readers return the RAW configured tier,
// so the effective tier is resolved here from the studio's switches.
export function classTagText({
  tier, flex, committed = false, cancelled = false, flexDeadlineShort = null,
  guaranteesEnabled = true, flexEnabled = true,
}) {
  const rawFlex = tier === "flex" || flex === true;
  if (rawFlex) {
    if (!flexEnabled) return { show: false, text: "", isFlex: false };
    if (cancelled) return { show: true, text: "flex", isFlex: true };
    if (committed) return { show: true, text: "flex · confirmed", isFlex: true };
    if (flexDeadlineShort) return { show: true, text: `flex · decided by ${flexDeadlineShort}`, isFlex: true };
    return { show: true, text: "flex", isFlex: true };
  }
  if (tier === "always") return { show: false, text: "", isFlex: false };
  if (!guaranteesEnabled) return { show: false, text: "", isFlex: false };
  return { show: true, text: "core", isFlex: false };
}
