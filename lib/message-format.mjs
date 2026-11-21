// Decision 89 (b): a studio message's line breaks. Mirrors the SQL
// message_paragraphs_html so the email and the app read the same.

/** Windows and old-Mac line endings to \n, runs of 3+ breaks to one blank line. */
export function normaliseMessage(text) {
  return String(text ?? "").replace(/\r\n?/g, "\n").replace(/\n{3,}/g, "\n\n");
}

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/** A blank line starts a paragraph; a single break is a <br>. */
export function messageParagraphsHtml(text) {
  return normaliseMessage(text)
    .split(/\n[ \t]*\n/)
    .map((p) => p.replace(/^\n+|\n+$/g, ""))
    .filter((p) => p.trim() !== "")
    .map((p) => `<p style="margin:0 0 10px">${esc(p).replace(/\n/g, "<br>")}</p>`)
    .join("");
}
