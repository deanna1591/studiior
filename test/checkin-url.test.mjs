import { test } from "node:test";
import assert from "node:assert/strict";
import { checkinPath, checkinUrl } from "../lib/checkin-url.mjs";

test("checkinPath is /checkin/{slug}", () => {
  assert.equal(checkinPath("deadbeef1234"), "/checkin/deadbeef1234");
});

test("checkinUrl joins the member origin and the path, trimming a trailing slash", () => {
  assert.equal(
    checkinUrl("https://reform.studiior.app", "ab12cd34"),
    "https://reform.studiior.app/checkin/ab12cd34",
  );
  assert.equal(
    checkinUrl("https://reform.studiior.app/", "ab12cd34"),
    "https://reform.studiior.app/checkin/ab12cd34",
  );
});
