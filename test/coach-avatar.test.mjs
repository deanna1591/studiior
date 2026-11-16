import { test } from "node:test";
import assert from "node:assert/strict";
import { avatarInitials, rendersPhoto } from "../lib/coach-avatar.mjs";

test("a row with a photo renders the image, without renders initials", () => {
  // with a photo url -> the image
  assert.equal(rendersPhoto("https://x/p.jpg"), true);
  // no url -> initials from the name
  assert.equal(rendersPhoto(null), false);
  assert.equal(rendersPhoto(""), false);
  assert.equal(rendersPhoto("   "), false);
});

test("initials: up to two from the name", () => {
  assert.equal(avatarInitials("Ada Example"), "AE");
  assert.equal(avatarInitials("Nikko"), "N");
  assert.equal(avatarInitials("ada  marie  example"), "AM");
  assert.equal(avatarInitials(""), "");
  assert.equal(avatarInitials(null), "");
});
