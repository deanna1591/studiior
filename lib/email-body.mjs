// Decision 77 — THE one renderer for a composed email body. Pure, no imports, so
// `node --test` runs it (test/email-body.test.mjs) and the Next preview + the
// campaign/closure/retention senders all parse the markup in exactly one place.
//
// Decision 80a grows the markup by four blocks (a button, a card, a quote, a
// divider) on top of the original paragraphs / **bold** / links / images:
//   - a blank line separates blocks;
//   - **bold** → <strong>;
//   - [text](https://url) → a link, http/https only (else the literal text);
//   - ![alt](url) ALONE on a line → a full-width <img alt="…">;
//   - [Label](https://url){button} ALONE in a block → a bulletproof (table)
//     button in the accent colour;
//   - a block of `::: card` … `:::` with name/detail/price/button lines → a
//     bordered single-column card; `::: plan <id>` / `::: class <id>` resolve
//     to those lines through a caller-supplied resolver (opts.resolve);
//   - a block whose every line starts with `> ` → an indented quote, with a
//     trailing ` — Name` shown as the attribution;
//   - a block that is exactly `---` → a 1px rule;
//   - everything else is HTML-escaped. No headings, colours, raw HTML.
//
// renderBody(text, opts?) → { html, text }. The one-arg call is unchanged, so
// every existing body renders identically (test/email-body.test.mjs). opts:
//   - accent: the button/card button background. A real "#rrggbb" is paired with
//     a readable text colour here; the literal token "{accent}" (used by the
//     SQL-rendered system templates, which are static and filled per-studio by
//     render_notification) emits "{accent}" / "{accent_on}" for SQL to fill.
//   - resolve(kind, id) → { name, detail?, price?, button?: {label,url} } | null,
//     for the ::: plan / ::: class shorthands (Next supplies it from the DB).
//
// All block HTML is table-based and inline-styled — no CSS classes — so it
// survives Gmail, Apple Mail and Outlook.

const EMAIL_FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif";
const NEUTRAL_ACCENT = "#78716C";
const INK = "#14170E";
const MUTED = "#57534E";
const LINE = "#E7E5E4";

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

/**
 * A button/card destination may ALSO be a bare `{placeholder}` token — the
 * SQL-rendered system templates author their buttons with {buy_url}/{manage_link}
 * and render_notification fills them. Harmless in a composed body (a literal
 * {token} is a dead link, escaped, never an injection). Inline [text](url) links
 * are NOT relaxed — they stay http-only so existing bodies render identically.
 */
function isButtonUrl(url) {
  const u = String(url).trim();
  return isSafeUrl(u) || /^\{[a-zA-Z_]+\}$/.test(u);
}

/**
 * A readable text colour on an accent fill. A real hex is paired here by
 * brightness (YIQ, the well-known approximation) so a pale accent (lime) gets
 * dark ink and a dark one gets white; the "{accent}" token — the SQL templates'
 * static case — hands the pairing to render_notification's `{accent_on}`.
 */
function onAccent(accent) {
  const m = /^#?([0-9a-f]{6})$/i.exec(String(accent).trim());
  if (!m) return "{accent_on}";
  const n = parseInt(m[1], 16);
  const r = (n >> 16) & 255, g = (n >> 8) & 255, b = n & 255;
  return (r * 299 + g * 587 + b * 114) / 1000 >= 150 ? INK : "#FFFFFF";
}

const IMG_LINE = /^!\[([^\]]*)\]\(([^)]*)\)$/;       // ![alt](url) alone on a line
const BUTTON_LINE = /^\[([^\]]+)\]\(([^)]+)\)\{button\}$/; // [Label](url){button} alone
const LINK = /\[([^\]]+)\]\(([^)]+)\)/g;             // [text](url)
const BOLD = /\*\*([^*]+)\*\*/g;                     // **bold**
const SHORTHAND = /^:::\s+(plan|class)\s+(.+)$/;     // ::: plan <id>

/**
 * Inline markup for one run of text (already split on image lines). Escapes
 * first, then re-introduces ONLY the markup we allow, on the escaped string, so
 * a `<script>` in the body can never become a tag. Links whose URL is not
 * http(s) are emitted as their literal text (escaped), never as an anchor.
 */
function inlineHtml(run) {
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

/** A bulletproof (table) button. Returns "" for an unsafe URL. */
function buttonHtml(label, url, accent, accentOn) {
  if (!isButtonUrl(url)) return "";
  return (
    `<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0">` +
    `<tr><td align="center" style="border-radius:6px;background:${accent}">` +
    `<a href="${esc(String(url).trim())}" style="display:inline-block;padding:11px 24px;` +
    `font-family:${EMAIL_FONT};font-size:15px;font-weight:600;line-height:1;` +
    `color:${accentOn};text-decoration:none;border-radius:6px">${esc(label)}</a>` +
    `</td></tr></table>`
  );
}

/** A bordered single-column card from { name, detail, price, button }. */
function cardHtml(c, accent, accentOn) {
  const rows = [];
  if (c.name) rows.push(`<div style="font-family:${EMAIL_FONT};font-size:16px;font-weight:600;color:${INK}">${esc(c.name)}</div>`);
  if (c.detail) rows.push(`<div style="font-family:${EMAIL_FONT};font-size:14px;line-height:20px;color:${MUTED};margin-top:4px">${esc(c.detail)}</div>`);
  if (c.price) rows.push(`<div style="font-family:${EMAIL_FONT};font-size:15px;font-weight:600;color:${INK};margin-top:8px">${esc(c.price)}</div>`);
  if (c.button && c.button.label && isButtonUrl(c.button.url)) {
    rows.push(`<div style="margin-top:4px">${buttonHtml(c.button.label, c.button.url, accent, accentOn)}</div>`);
  }
  if (rows.length === 0) return "";
  return (
    `<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0">` +
    `<tr><td style="border:1px solid ${LINE};border-radius:8px;padding:16px">` +
    rows.join("") +
    `</td></tr></table>`
  );
}

/** Parse the body of a `::: card` block (name/detail/price/button lines). */
function parseCardLines(lines) {
  const c = {};
  for (const raw of lines) {
    const line = raw.trim();
    const colon = line.indexOf(":");
    if (colon < 0) { c.detail = c.detail ? c.detail + " " + line : line; continue; }
    const k = line.slice(0, colon).trim().toLowerCase();
    const v = line.slice(colon + 1).trim();
    if (k === "name") c.name = v;
    else if (k === "detail") c.detail = v;
    else if (k === "price") c.price = v;
    else if (k === "button") {
      const bar = v.indexOf("|");
      if (bar >= 0) c.button = { label: v.slice(0, bar).trim(), url: v.slice(bar + 1).trim() };
    } else {
      c.detail = c.detail ? c.detail + " " + line : line;
    }
  }
  return c;
}

/** A card's plain-text form. */
function cardText(c) {
  const parts = [];
  if (c.name) parts.push(c.name);
  if (c.detail) parts.push(c.detail);
  if (c.price) parts.push(c.price);
  if (c.button && c.button.label) parts.push(`${c.button.label}: ${c.button.url}`);
  return parts.join("\n");
}

/** An indented quote, with a trailing " — Name" shown as attribution. */
function quoteHtml(lines) {
  let body = lines.map((l) => l.replace(/^>\s?/, "")).join("\n");
  let name = null;
  const m = /\s+[—-]\s+([^\n]+)$/.exec(body);
  if (m) { name = m[1].trim(); body = body.slice(0, m.index); }
  const bodyHtml = body.split("\n").map(inlineHtml).join("<br>");
  const nameHtml = name
    ? `<div style="font-family:${EMAIL_FONT};font-size:13px;color:#78716C;margin-top:6px">— ${esc(name)}</div>`
    : "";
  return (
    `<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0">` +
    `<tr><td style="border-left:3px solid ${LINE};padding:2px 0 2px 16px">` +
    `<div style="font-family:${EMAIL_FONT};font-size:15px;line-height:22px;font-style:italic;color:#44403C">${bodyHtml}</div>` +
    nameHtml +
    `</td></tr></table>`
  );
}

function quoteText(lines) {
  return lines.map((l) => l.replace(/^>\s?/, "")).join("\n");
}

const DIVIDER_HTML =
  `<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:20px 0">` +
  `<tr><td style="border-top:1px solid ${LINE};font-size:1px;line-height:1px;height:1px">&nbsp;</td></tr></table>`;

/**
 * @param {string} input the composed body
 * @param {{accent?: string, resolve?: (kind: string, id: string) => any}} [opts]
 * @returns {{ html: string, text: string }}
 */
export function renderBody(input, opts = {}) {
  const accent = opts.accent || NEUTRAL_ACCENT;
  const accentOn = onAccent(accent);
  const resolve = typeof opts.resolve === "function" ? opts.resolve : null;

  const src = String(input ?? "").replace(/\r\n/g, "\n");
  const blocks = src.split(/\n{2,}/);

  const htmlParts = [];
  const textParts = [];
  for (const raw of blocks) {
    const block = raw.replace(/^\n+|\n+$/g, "");
    if (block === "") continue;
    const trimmed = block.trim();

    // Divider — a block that is exactly ---
    if (trimmed === "---") {
      htmlParts.push(DIVIDER_HTML);
      continue; // no plain-text line for a rule
    }

    // Button — [Label](url){button} alone in a block
    const btn = BUTTON_LINE.exec(trimmed);
    if (btn && isButtonUrl(btn[2])) {
      htmlParts.push(buttonHtml(btn[1], btn[2], accent, accentOn));
      textParts.push(`${btn[1]}: ${btn[2].trim()}`);
      continue;
    }

    // Card — ::: card … :::  or the ::: plan/class <id> shorthand
    if (trimmed.startsWith(":::")) {
      const lines = trimmed.split("\n");
      const short = SHORTHAND.exec(lines[0].trim());
      if (short) {
        const data = resolve ? resolve(short[1], short[2].trim()) : null;
        if (data) {
          const html = cardHtml(data, accent, accentOn);
          if (html) { htmlParts.push(html); textParts.push(cardText(data)); continue; }
        }
        // No resolver / nothing resolved — degrade to the literal text.
        htmlParts.push("<p>" + inlineHtml(trimmed) + "</p>");
        textParts.push(inlineText(trimmed));
        continue;
      }
      if (/^:::\s+card$/.test(lines[0].trim())) {
        const inner = lines.slice(1).filter((l) => l.trim() !== ":::");
        const c = parseCardLines(inner);
        const html = cardHtml(c, accent, accentOn);
        if (html) { htmlParts.push(html); textParts.push(cardText(c)); continue; }
        // An empty card falls through to a paragraph.
      }
    }

    // Quote — every non-empty line begins with >
    const qlines = block.split("\n");
    if (qlines.every((l) => /^>\s?/.test(l))) {
      htmlParts.push(quoteHtml(qlines));
      textParts.push(quoteText(qlines));
      continue;
    }

    // Image — ![alt](url) alone on a line
    const img = IMG_LINE.exec(trimmed);
    if (img) {
      const [, alt, url] = img;
      if (isSafeUrl(url.trim())) {
        htmlParts.push(
          `<img src="${esc(url.trim())}" alt="${esc(alt)}" style="display:block;width:100%;max-width:100%;height:auto;margin:16px 0;" />`,
        );
        textParts.push(`[${alt || "image"}]`);
        continue;
      }
    }

    // A paragraph: single newlines inside become <br>.
    const lines = block.split("\n");
    htmlParts.push("<p>" + lines.map(inlineHtml).join("<br>") + "</p>");
    textParts.push(lines.map(inlineText).join("\n"));
  }

  return {
    html: htmlParts.join("\n"),
    text: textParts.join("\n\n"),
  };
}
