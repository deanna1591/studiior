// Decision 79b — the AI-draft prompt and the STRICT parse of the model's reply.
// Pure: no network, so a node test can pin the prompt and the parse with fixtures.

const SITUATION_HINT = {
  unconverted: "They took a free class and have not bought yet — invite them back warmly.",
  at_risk: "They were a regular and have slipped — a personal, no-pressure check-in.",
  drifting: "They have gone a little quiet — a soft, friendly note.",
  expiring: "Their plan is ending soon — a gentle renewal nudge.",
  lapsed: "Their plan ended a while ago — a warm win-back.",
};

/** The system + user messages for the Anthropic Messages API. */
export function buildPrompt(ctx, voice, currentSubject, currentBody, situation) {
  const c = ctx ?? {};
  const facts = [
    `Member first name: ${c.first_name ?? "there"}`,
    `Studio: ${c.studio_name ?? ""}`,
    c.last_class ? `Last class: ${c.last_class}${c.last_class_date ? ` on ${c.last_class_date}` : ""}${c.instructor_first ? ` with ${c.instructor_first}` : ""}` : null,
    c.days_since ? `Days since last visit: ${c.days_since}` : null,
    c.plan_name ? `Plan: ${c.plan_name}` : null,
    c.expires_on ? `Plan ends: ${c.expires_on}` : null,
    c.offer_plan_name ? `Offer: ${c.offer_plan_name}` : null,
  ].filter(Boolean).join("\n");

  const system =
    "You write a short retention email for a boutique fitness studio to one member. " +
    "Write in the studio's own voice. Keep it to 120 words or fewer. Write in the first person plural, as the studio. " +
    "Write in English. Promise NOTHING that is not in the facts: no discounts, no prices, no dates that were not supplied, no classes that were not named, no booking link or offer you were not given. " +
    'Reply with ONLY a JSON object: {"subject": "...", "body": "..."}. ' +
    "The body is plain text where a blank line is a new paragraph, **bold** marks emphasis, and [text](https://url) is a link. No other keys, no commentary.";

  const user =
    (voice && String(voice).trim() ? `How this studio speaks:\n${String(voice).trim()}\n\n` : "") +
    `Situation: ${SITUATION_HINT[situation] ?? "A friendly retention note."}\n\n` +
    `Facts (do not go beyond these):\n${facts}\n\n` +
    `The studio's current draft, to rewrite in their voice:\nSubject: ${currentSubject ?? ""}\n\n${currentBody ?? ""}`;

  return { system, user };
}

/** The bulk variant: one body for many members, so the model keeps {placeholders}
 *  (it does not know any one member), rewriting only the voice. */
export function buildBulkPrompt(voice, currentSubject, currentBody, situation) {
  const system =
    "You rewrite a retention email TEMPLATE for a boutique fitness studio in the studio's own voice. " +
    "This one email goes to many members, so keep EVERY {placeholder} token (like {first_name}, {last_class}, {book_url}) exactly as written — do not fill them in, do not remove them, do not add new ones. " +
    "Keep it to 120 words or fewer, first person plural as the studio, English. Promise nothing not already in the template: no discounts, no prices, no new links. " +
    'Reply with ONLY a JSON object: {"subject": "...", "body": "..."} — the body in plain text with blank-line paragraphs, **bold**, and [text](url). No commentary.';
  const user =
    (voice && String(voice).trim() ? `How this studio speaks:\n${String(voice).trim()}\n\n` : "") +
    `Situation: ${SITUATION_HINT[situation] ?? "A friendly retention note."}\n\n` +
    `The template to rewrite (keep the {placeholders}):\nSubject: ${currentSubject ?? ""}\n\n${currentBody ?? ""}`;
  return { system, user };
}

/** STRICT: only a JSON object with a non-empty string subject AND body passes. */
export function parseDraft(text) {
  if (typeof text !== "string") return null;
  let raw = text.trim();
  const fence = raw.match(/^```(?:json)?\s*([\s\S]*?)\s*```$/);
  if (fence) raw = fence[1].trim();
  const start = raw.indexOf("{"); const end = raw.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  let obj;
  try { obj = JSON.parse(raw.slice(start, end + 1)); } catch { return null; }
  if (!obj || typeof obj !== "object" || Array.isArray(obj)) return null;
  const { subject, body } = obj;
  if (typeof subject !== "string" || typeof body !== "string") return null;
  if (!subject.trim() || !body.trim()) return null;
  return { subject: subject.trim(), body: body.trim() };
}

/** The text and token usage out of an Anthropic Messages API response. */
export function parseApiResponse(json) {
  const text = Array.isArray(json?.content)
    ? json.content.filter((b) => b && b.type === "text").map((b) => b.text).join("")
    : "";
  return {
    text,
    inputTokens: json?.usage?.input_tokens ?? null,
    outputTokens: json?.usage?.output_tokens ?? null,
  };
}
