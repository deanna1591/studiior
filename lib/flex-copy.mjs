/**
 * The standalone-flex warning sentence — pure, so `node --test` can guard it.
 *
 * A standalone flex slot (nothing of the instructor's beside it) is a
 * standby-fee obligation under the instructor agreement AT A STUDIO THAT PAYS
 * ONE. Reform sets flex_standby_pay_cents = 0, so the old unconditional "so it
 * carries a standby fee" was a false statement to the owner. The caller passes
 * the FORMATTED amount (via the app's existing money formatter) only when the
 * studio's standby pay is > 0; a falsy amount means "say nothing".
 */

/**
 * @param {string|null|undefined} standbyText  formatted amount, or null when the
 *   studio's flex_standby_pay_cents is 0 (then the sentence is empty).
 * @param {number} [count]  how many standalone flex classes (1 for a one-off).
 * @returns {string} a leading-space sentence to append, or "".
 */
export function standaloneFlexSentence(standbyText, count = 1) {
  if (!standbyText) return "";
  if (count <= 1) {
    return ` It is a standalone flex class — no other class of that instructor`
      + ` beside it — so it carries the ${standbyText} standby fee.`;
  }
  return ` ${count} of them are standalone flex classes — no other class of that`
    + ` instructor beside them — so each carries the ${standbyText} standby fee.`;
}
