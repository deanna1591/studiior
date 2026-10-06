import { test } from "node:test";
import assert from "node:assert/strict";
import { parseFingerprints, assetlinksFor, aasaFor, isPackageId, isTeamId } from "../lib/well-known.mjs";

const FP1 = "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99";
const FP2 = "11:22:33:44:55:66:77:88:99:00:AA:BB:CC:DD:EE:FF:11:22:33:44:55:66:77:88:99:00:AA:BB:CC:DD:EE:FF";

test("parseFingerprints: good, comma- and newline-separated", () => {
  const r = parseFingerprints(`${FP1}, ${FP2}`);
  assert.deepEqual(r.valid, [FP1, FP2]);
  assert.deepEqual(r.invalid, []);
  const r2 = parseFingerprints(`${FP1}\n${FP2}`);
  assert.deepEqual(r2.valid, [FP1, FP2]);
});
test("parseFingerprints: lowercase is upper-cased", () => {
  const r = parseFingerprints(FP1.toLowerCase());
  assert.deepEqual(r.valid, [FP1]);
});
test("parseFingerprints: a bad entry is rejected, the good one kept", () => {
  const r = parseFingerprints(`${FP1}, not-a-fingerprint, AA:BB`);
  assert.deepEqual(r.valid, [FP1]);
  assert.deepEqual(r.invalid, ["not-a-fingerprint", "AA:BB"]);
});
test("parseFingerprints: empty / non-string -> empty", () => {
  assert.deepEqual(parseFingerprints(""), { valid: [], invalid: [] });
  assert.deepEqual(parseFingerprints(null), { valid: [], invalid: [] });
});
test("parseFingerprints: duplicates collapsed", () => {
  assert.deepEqual(parseFingerprints(`${FP1},${FP1}`).valid, [FP1]);
});

test("assetlinksFor: null when package or fingerprints missing", () => {
  assert.equal(assetlinksFor({ androidPackage: "app.studiior.reformcollective", fingerprints: [] }), null);
  assert.equal(assetlinksFor({ androidPackage: "", fingerprints: [FP1] }), null);
  assert.equal(assetlinksFor({}), null);
});
test("assetlinksFor: complete shape, exact keys", () => {
  const a = assetlinksFor({ androidPackage: "app.studiior.reformcollective", fingerprints: [FP1, FP2] });
  assert.equal(Array.isArray(a), true);
  assert.deepEqual(a[0].relation, ["delegate_permission/common.handle_all_urls"]);
  assert.equal(a[0].target.namespace, "android_app");
  assert.equal(a[0].target.package_name, "app.studiior.reformcollective");
  assert.deepEqual(a[0].target.sha256_cert_fingerprints, [FP1, FP2]);
  assert.deepEqual(Object.keys(a[0]), ["relation", "target"]);
  assert.deepEqual(Object.keys(a[0].target), ["namespace", "package_name", "sha256_cert_fingerprints"]);
});

test("aasaFor: null when team or bundle missing/invalid", () => {
  assert.equal(aasaFor({ teamId: "ABCDE12345", bundleId: "" }), null);
  assert.equal(aasaFor({ teamId: "short", bundleId: "app.studiior.reformcollective" }), null);
  assert.equal(aasaFor({}), null);
});
test("aasaFor: complete shape, TEAMID.bundle", () => {
  const a = aasaFor({ teamId: "ABCDE12345", bundleId: "app.studiior.reformcollective" });
  assert.deepEqual(a.applinks.apps, []);
  assert.deepEqual(a.applinks.details, [{ appID: "ABCDE12345.app.studiior.reformcollective", paths: ["*"] }]);
  assert.deepEqual(a.webcredentials.apps, ["ABCDE12345.app.studiior.reformcollective"]);
  assert.deepEqual(Object.keys(a), ["applinks", "webcredentials"]);
});

test("isPackageId / isTeamId", () => {
  assert.equal(isPackageId("app.studiior.reformcollective"), true);
  assert.equal(isPackageId("nodot"), false);
  assert.equal(isPackageId("1bad.start"), false);
  assert.equal(isTeamId("ABCDE12345"), true);
  assert.equal(isTeamId("abcde12345"), false);
  assert.equal(isTeamId("ABCDE1234"), false);
});
