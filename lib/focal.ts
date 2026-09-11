/**
 * Where a cropped photograph is anchored.
 *
 * `object-fit: cover` crops around the geometric centre, and on a phone that is
 * brutal: a 1600×600 photograph in a 375×812 frame is scaled to fill the height
 * and 375 of its 2165 scaled pixels survive — SEVENTEEN PER CENT, dead centre.
 * A studio's shot of its reformers is rarely centred, so the middle of the frame
 * is usually not the thing worth keeping.
 *
 * Composed here from two bounded ints rather than stored as a string, because
 * the result goes into an inline style and a text column would be a value from
 * the database landing in a style attribute. The database bounds them 0–100 and
 * this clamps again — a column added later, or a row written before the CHECK,
 * cannot put anything but a percentage on the page.
 */
export function focalPoint(x: number | null | undefined,
                           y: number | null | undefined): string {
  const clamp = (n: number | null | undefined) =>
    Math.min(100, Math.max(0, Math.round(Number.isFinite(Number(n)) ? Number(n) : 50)));
  return `${clamp(x)}% ${clamp(y)}%`;
}

/**
 * The phone the crop is being judged against.
 *
 * The branding screen used to preview the login photo in a 28px-tall full-width
 * band, which is the one shape that always looks fine and is the reason nobody
 * saw the problem. These are the real proportions of the two places a studio's
 * photographs are cropped hardest.
 */
export const PHONE_LOGIN = { w: 375, h: 812 };   // the full-bleed sign-in screen
export const PHONE_HERO  = { w: 343, h: 172 };   // .m-hero, the member app's card
