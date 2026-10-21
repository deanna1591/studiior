import { test } from "node:test";
import assert from "node:assert/strict";
import { buildPrompt, buildBulkPrompt, parseDraft, parseApiResponse } from "../lib/ai-draft.mjs";

const CTX = {
  first_name: "Ava", studio_name: "Reform Collective",
  last_class: "Barre", last_class_date: "09 Nov", instructor_first: "Ada",
  days_since: "16", plan_name: "Unlimited Monthly", expires_on: "",
  offer_plan_name: "a membership",
};

test("buildPrompt carries the facts and the guardrails", () => {
  const { system, user } = buildPrompt(CTX, "Warm, playful, never pushy.", "We miss you", "Hi Ava,\n\nCome back.", "at_risk");
  assert.match(system, /120 words or fewer/);
  assert.match(system, /Promise NOTHING that is not in the facts/);
  assert.match(system, /ONLY a JSON object/);
  assert.match(user, /How this studio speaks:\nWarm, playful, never pushy\./);
  assert.match(user, /Member first name: Ava/);
  assert.match(user, /Last class: Barre on 09 Nov with Ada/);
  assert.match(user, /Days since last visit: 16/);
  assert.match(user, /Plan: Unlimited Monthly/);
  assert.match(user, /We miss you/);
  // An empty fact is omitted, not rendered blank.
  assert.doesNotMatch(user, /Plan ends:/);
});

test("buildPrompt without a voice omits the voice block", () => {
  const { user } = buildPrompt(CTX, "", "s", "b", "drifting");
  assert.doesNotMatch(user, /How this studio speaks/);
  assert.match(user, /gone a little quiet/);
});

test("buildBulkPrompt keeps the placeholders and the voice", () => {
  const { system, user } = buildBulkPrompt("Brisk and kind.", "Hi {first_name}", "Come to {last_class}, {first_name}.", "lapsed");
  assert.match(system, /keep EVERY \{placeholder\} token/);
  assert.match(system, /120 words or fewer/);
  assert.match(user, /How this studio speaks:\nBrisk and kind\./);
  assert.match(user, /\{first_name\}/);
  assert.match(user, /\{last_class\}/);
});

test("parseDraft accepts a clean JSON object", () => {
  assert.deepEqual(parseDraft('{"subject":"Hi","body":"Come back **soon**."}'),
    { subject: "Hi", body: "Come back **soon**." });
});

test("parseDraft tolerates a ```json fence and surrounding text", () => {
  assert.deepEqual(parseDraft('```json\n{"subject":"A","body":"B"}\n```'), { subject: "A", body: "B" });
  assert.deepEqual(parseDraft('Here you go:\n{"subject":"A","body":"B"}'), { subject: "A", body: "B" });
});

test("parseDraft rejects anything that is not subject + body", () => {
  assert.equal(parseDraft('{"subject":"Only subject"}'), null);
  assert.equal(parseDraft('{"body":"Only body"}'), null);
  assert.equal(parseDraft('{"subject":"","body":"x"}'), null);
  assert.equal(parseDraft('{"subject":"x","body":"   "}'), null);
  assert.equal(parseDraft('{"subject":1,"body":"x"}'), null);
  assert.equal(parseDraft('["subject","body"]'), null);
  assert.equal(parseDraft("just some prose, no json"), null);
  assert.equal(parseDraft(""), null);
  assert.equal(parseDraft(null), null);
});

test("parseApiResponse pulls text and token usage", () => {
  const r = parseApiResponse({
    content: [{ type: "text", text: '{"subject":"A",' }, { type: "text", text: '"body":"B"}' }],
    usage: { input_tokens: 120, output_tokens: 48 },
  });
  assert.equal(r.text, '{"subject":"A","body":"B"}');
  assert.equal(r.inputTokens, 120);
  assert.equal(r.outputTokens, 48);
  const empty = parseApiResponse({});
  assert.equal(empty.text, "");
  assert.equal(empty.inputTokens, null);
});
