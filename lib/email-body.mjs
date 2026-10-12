// Decision 77 — THE one renderer for a composed email body. Pure, no imports, so
// `node --test` runs it (test/email-body.test.mjs) and the Next preview + the
// campaign/closure senders all parse the markup in exactly one place. The SQL
// paragraph-split renderers in 20260832170000 are retired in favour of this.
//
// The markup is small and fixed (Decision 77a):
//   - a blank line separates paragraphs;
//   - **bold** → <strong>;
//   - [text](https://url) → a link, http/https only (anything else is left as
//     the literal text, never a link);
//   - ![alt](url) ALONE on a line → a full-width <img alt="…">;
//   - everything else is HTML-escaped. No headings, colours, tables or raw HTML.
//
// renderBody(text) → { html, text }. The text output keeps the words, drops the
// markup, and turns an image into "[alt]".

/** Escape the five HTML-significant characters. */
function esc(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/** http(s) only; everything else is not a link we will emit. */
function isSafeUrl(url) {
  return /^https?:\/\/[^\s)]+$/i.test(url);
}

const IMG_LINE = /^!\[([^\]]*)\]\(([^)]*)\)$/;       // ![alt](url) alone on a line
const LINK = /\[([^\]]+)\]\(([^)]+)\)/g;             // [text](url)
const BOLD = /\*\*([^*]+)\*\*/g;                     // **bold**

/**
 * Inline markup for one run of text (already split on image lines). Escapes
 * first, then re-introduces ONLY the markup we allow, on the escaped string, so
 * a `<script>` in the body can never become a tag. Links whose URL is not
 * http(s) are emitted as their literal text (escaped), never as an anchor.
 */
function inlineHtml(run) {
  // Tokenise links on the RAW run (so the URL is checked before escaping), then
  // escape each piece and rebuild. Bold is applied to the escaped text pieces.
  let out = "";
  let last = 0;
  let m;
  LINK.lastIndex = 0;
  while ((m = LINK.exec(run)) !== null) {
    out += boldHtml(esc(run.slice(last, m.index)));
    const [whole, label, url] = m;
    if (isSafeUrl(url.trim())) {
      out += `<a href="${esc(url.trim())}">${boldHtml(esc(label))}</a>`;
    } else {
      // Not a safe link — keep the literal source text, escaped.
      out += boldHtml(esc(whole));
    }
    last = m.index + whole.length;
  }
  out += boldHtml(esc(run.slice(last)));
  return out;
}

/** **bold** on an ALREADY-ESCAPED string (no HTML can be introduced by it). */
function boldHtml(escaped) {
  return escaped.replace(BOLD, "<strong>$1</strong>");
}

/** Strip the inline markup for the plain-text output (links → their text). */
function inlineText(run) {
  return run
    .replace(LINK, (whole, label, url) => (isSafeUrl(url.trim()) ? label : whole))
    .replace(BOLD, "$1");
}

/**
 * @param {string} input the composed body
 * @returns {{ html: string, text: string }}
 */
export function renderBody(input) {
  const src = String(input ?? "").replace(/\r\n/g, "\n");
  // Split into blocks on one or more blank lines. A block is either a single
  // image line (its own full-width <img>) or a paragraph of inline text.
  const blocks = src.split(/\n{2,}/);

  const htmlParts = [];
  const textParts = [];
  for (const raw of blocks) {
    const block = raw.replace(/^\n+|\n+$/g, "");
    if (block === "") continue;

    const img = IMG_LINE.exec(block.trim());
    if (img) {
      const [, alt, url] = img;
      if (isSafeUrl(url.trim())) {
        htmlParts.push(
          `<img src="${esc(url.trim())}" alt="${esc(alt)}" style="display:block;width:100%;max-width:100%;height:auto;margin:16px 0;" />`,
        );
        textParts.push(`[${alt || "image"}]`);
        continue;
      }
      // An image line with an unsafe URL falls through to ordinary text.
    }

    // A paragraph: single newlines inside become <br>. Each text run between
    // newlines is inline-rendered.
    const lines = block.split("\n");
    htmlParts.push("<p>" + lines.map(inlineHtml).join("<br>") + "</p>");
    textParts.push(lines.map(inlineText).join("\n"));
  }

  return {
    html: htmlParts.join("\n"),
    text: textParts.join("\n\n"),
  };
}
