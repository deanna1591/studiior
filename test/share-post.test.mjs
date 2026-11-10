import { test } from "node:test";
import assert from "node:assert/strict";
import { pickShareMode, SHARE_FALLBACK_TOAST } from "../lib/share-post.mjs";
import { captionText } from "../lib/schedule-post.mjs";

// pickShareMode only passes `file` into nav.canShare({files:[file]}); a stand-in
// truthy object is enough (the mock navigator ignores its shape).
const file = { name: "post.png" };

test("share: pickShareMode is 'share' when the platform can share files", () => {
  const nav = { canShare: (d) => Array.isArray(d.files) && d.files.length === 1, share: async () => {} };
  assert.equal(pickShareMode(nav, file), "share");
});

test("share: pickShareMode falls back when canShare says no", () => {
  const nav = { canShare: () => false, share: async () => {} };
  assert.equal(pickShareMode(nav, file), "fallback");
});

test("share: pickShareMode falls back with no nav, no share/canShare, a throw, or no file", () => {
  assert.equal(pickShareMode(null, file), "fallback");
  assert.equal(pickShareMode(undefined, file), "fallback");
  assert.equal(pickShareMode({}, file), "fallback");
  assert.equal(pickShareMode({ share: async () => {} }, file), "fallback");       // no canShare
  assert.equal(pickShareMode({ canShare: () => true }, file), "fallback");         // no share
  assert.equal(pickShareMode({ canShare: () => { throw new Error("x"); }, share: async () => {} }, file), "fallback");
  assert.equal(pickShareMode({ canShare: () => true, share: async () => {} }, null), "fallback"); // no file
});

test("share: the download-and-copy fallback toast is the exact sentence", () => {
  assert.equal(SHARE_FALLBACK_TOAST, "Image saved and caption copied. Paste it into your post.");
});

test("instructor post: the caption starts with the coach's name", () => {
  const days = [{ date: "2026-11-16", label: "Monday 16 Nov", count: 1, classes: [
    { time: "7:00 AM", name: "Reformer Flow", coach: "Ada", tier: "core", spots_left: 2 },
  ] }];
  const cap = captionText({ days, hashtags: "#reform", coachFirst: "Ada", mode: "week" });
  assert.ok(cap.startsWith("Ada's classes"), `caption should start with the coach name, got: ${cap.slice(0, 40)}`);
});
