import { test } from "node:test";
import assert from "node:assert/strict";
import { slugFromCheckinUrl } from "../lib/checkin-scan.mjs";

const HOST = "reform.studiior.app";

test("accepts this studio's member-host check-in URL → the token", () => {
  assert.equal(
    slugFromCheckinUrl("https://reform.studiior.app/checkin/9f2a1c0b4e8d6a7f0123456789abcdef", HOST),
    "9f2a1c0b4e8d6a7f0123456789abcdef",
  );
});

test("a trailing slash is accepted", () => {
  assert.equal(slugFromCheckinUrl("https://reform.studiior.app/checkin/abc123/", HOST), "abc123");
});

test("host comparison is case-insensitive", () => {
  assert.equal(slugFromCheckinUrl("https://REFORM.studiior.app/checkin/tok1", HOST), "tok1");
});

test("another studio's subdomain is rejected", () => {
  assert.equal(slugFromCheckinUrl("https://other.studiior.app/checkin/tok1", HOST), null);
});

test("another domain is rejected", () => {
  assert.equal(slugFromCheckinUrl("https://reform.evil.com/checkin/tok1", HOST), null);
});

test("a non-check-in path on the right host is rejected", () => {
  assert.equal(slugFromCheckinUrl("https://reform.studiior.app/book", HOST), null);
  assert.equal(slugFromCheckinUrl("https://reform.studiior.app/checkin", HOST), null);
  assert.equal(slugFromCheckinUrl("https://reform.studiior.app/checkin/tok/extra", HOST), null);
});

test("a non-URL string is rejected", () => {
  assert.equal(slugFromCheckinUrl("just-a-code", HOST), null);
  assert.equal(slugFromCheckinUrl("", HOST), null);
});

test("a non-http scheme is rejected", () => {
  assert.equal(slugFromCheckinUrl("javascript:alert(1)//reform.studiior.app/checkin/x", HOST), null);
});

test("a local dev host with a port matches exactly", () => {
  assert.equal(
    slugFromCheckinUrl("http://reform.localhost:3000/checkin/tok9", "reform.localhost:3000"),
    "tok9",
  );
  // same host without the port is a different host → rejected
  assert.equal(slugFromCheckinUrl("http://reform.localhost:3000/checkin/tok9", "reform.localhost"), null);
});

test("bad args → null", () => {
  assert.equal(slugFromCheckinUrl(null, HOST), null);
  assert.equal(slugFromCheckinUrl("https://reform.studiior.app/checkin/x", ""), null);
});
