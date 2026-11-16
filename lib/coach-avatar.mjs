/**
 * The coach photo on a Book/free-picker row (the regression fix). These mirror
 * what components/member/avatar.tsx renders: a photo when there is a url, else
 * up to two initials from the coach's name.
 */
export function avatarInitials(name) {
  return String(name || "").split(/\s+/).filter(Boolean).slice(0, 2)
    .map((w) => (w[0] || "").toUpperCase()).join("");
}
export function rendersPhoto(url) {
  return !!(url && String(url).trim());
}
