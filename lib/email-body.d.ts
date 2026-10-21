// Types for lib/email-body.mjs (Decision 77 + 80a). See the .mjs for the grammar.
export interface RenderBodyOptions {
  /** Button/card-button background. A real "#rrggbb" is paired with a readable
   *  text colour; the literal token "{accent}" emits "{accent}"/"{accent_on}"
   *  for render_notification to fill per-studio. Default neutral grey. */
  accent?: string;
  /** Resolve the ::: plan / ::: class shorthands to card fields. */
  resolve?: (kind: string, id: string) => {
    name?: string; detail?: string; price?: string;
    button?: { label: string; url: string };
  } | null;
}
export function renderBody(input: string, opts?: RenderBodyOptions): { html: string; text: string };
