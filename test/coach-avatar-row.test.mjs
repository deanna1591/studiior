// Decision 116(c): the "Coaches" filter row model. Run: node --test test/coach-avatar-row.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { coachAvatarRow, certificationLines } from "../lib/private-sessions.mjs";

const coaches = [
  { id: "a", first_name: "Ada", display_name: "Ada Example", avatar_url: "https://x/ada.jpg" },
  { id: "b", first_name: "Bo", display_name: "Bo Fictitious", avatar_url: null },
  { id: "c", display_name: "Cleo", avatar_url: "  " },
];

test("All comes first and is selected when nothing is filtered", () => {
  const r = coachAvatarRow(coaches, null);
  assert.equal(r.length, 4);
  assert.deepEqual(r[0], { id: null, label: "All", photo: null, initials: null, selected: true });
  assert.ok(r.slice(1).every((x) => !x.selected));
});

test("each coach shows the first name; a photo when there is one, else initials", () => {
  const [, a, b, c] = coachAvatarRow(coaches, null);
  assert.deepEqual(a, { id: "a", label: "Ada", photo: "https://x/ada.jpg", initials: null, selected: false });
  assert.deepEqual(b, { id: "b", label: "Bo", photo: null, initials: "BF", selected: false });
  assert.equal(c.label, "Cleo");
  assert.equal(c.photo, null);          // a blank url is no photo
  assert.equal(c.initials, "C");
});

test("selecting a coach marks only that coach", () => {
  const r = coachAvatarRow(coaches, "b");
  assert.deepEqual(r.map((x) => x.selected), [false, false, true, false]);
});

test("no coaches gives just All", () => {
  assert.deepEqual(coachAvatarRow([], null).map((x) => x.label), ["All"]);
});

test("certification lines: trimmed, empties dropped, non-lists give none", () => {
  assert.deepEqual(certificationLines([" BASI ", "", null, "Reformer 1-3"]), ["BASI", "Reformer 1-3"]);
  assert.deepEqual(certificationLines(null), []);
  assert.deepEqual(certificationLines("BASI"), []);
});
