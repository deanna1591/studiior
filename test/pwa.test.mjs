// Decision 51 — the PWA copy helpers and the per-tenant manifest shape.
// Run: node --test test/pwa.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  loginTagline, installWelcome, shortName, iconVersion, manifestObject, DEFAULT_LOGIN_TAGLINE,
} from "../lib/pwa.mjs";

test("loginTagline falls back to the default, trims, keeps a custom one", () => {
  assert.equal(loginTagline(null), DEFAULT_LOGIN_TAGLINE);
  assert.equal(loginTagline("  "), DEFAULT_LOGIN_TAGLINE);
  assert.equal(loginTagline("Move well."), "Move well.");
});

test("installWelcome names the studio by default, keeps a custom one", () => {
  assert.equal(installWelcome("Reform Collective", null),
    "Add Reform Collective to your home screen for one-tap booking.");
  assert.equal(installWelcome("Reform Collective", "Tap to book."), "Tap to book.");
});

test("shortName caps at 12 chars on a word boundary", () => {
  assert.equal(shortName("Reform"), "Reform");
  assert.equal(shortName("Reform Collective"), "Reform"); // word boundary before 12
  assert.equal(shortName("Supercalifragilistic"), "Supercalifra"); // hard 12-char cut, no early space
});

test("iconVersion is stable per URL and changes with the URL", () => {
  const a = iconVersion("https://x/logo-1.png");
  assert.equal(a, iconVersion("https://x/logo-1.png"));
  assert.notEqual(a, iconVersion("https://x/logo-2.png"));
  assert.equal(typeof iconVersion(null), "string"); // null -> "none", still a tag
});

test("manifestObject — member app: name, scope, colours, icons", () => {
  const m = manifestObject(
    { slug: "reform", name: "Reform Collective", themeColor: "#B85C38",
      backgroundColor: "#FAF6F2", iconV: "abc" }, "member");
  assert.equal(m.id, "reform");
  assert.equal(m.name, "Reform Collective");
  assert.equal(m.short_name, "Reform");
  assert.equal(m.start_url, "/");
  assert.equal(m.scope, "/");
  assert.equal(m.display, "standalone");
  assert.equal(m.theme_color, "#B85C38");
  assert.equal(m.background_color, "#FAF6F2");
  assert.equal(m.icons.length, 3);
  assert.ok(m.icons.every((i) => i.src.includes("?v=abc")));
  assert.equal(m.icons.find((i) => i.purpose === "maskable").src, "/icon/maskable?v=abc");
});

test("manifestObject — instructor app: separate name, id and scope", () => {
  const m = manifestObject(
    { slug: "reform", name: "Reform Collective", themeColor: "#B85C38",
      backgroundColor: "#FAF6F2", iconV: "abc" }, "instructor");
  assert.equal(m.id, "reform-instructor");
  assert.equal(m.name, "Reform Collective — Instructors");
  assert.equal(m.start_url, "/instructor");
  assert.equal(m.scope, "/instructor");
});

test("two tenants give two names and two theme colours", () => {
  const a = manifestObject({ slug: "reform", name: "Reform Collective",
    themeColor: "#B85C38", backgroundColor: "#FAF6F2", iconV: "a" }, "member");
  const b = manifestObject({ slug: "flow", name: "Flow Studio",
    themeColor: "#3355FF", backgroundColor: "#FFFFFF", iconV: "b" }, "member");
  assert.notEqual(a.name, b.name);
  assert.notEqual(a.theme_color, b.theme_color);
  assert.notEqual(a.id, b.id);
});
