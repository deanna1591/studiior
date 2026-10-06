// Decision 52a — the store-verification file builders, pure so the route
// handlers, the settings action and a node test all agree. No I/O, no Next
// imports.

const FP = /^([0-9A-F]{2}:){31}[0-9A-F]{2}$/;        // 32 upper-hex octets
const PKG = /^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$/;  // reverse-DNS

/**
 * Split a free-text list of SHA-256 fingerprints (commas and/or newlines),
 * trim, upper-case, and separate the valid from the invalid. Returns
 * { valid: string[], invalid: string[] } — invalid entries are the raw tokens
 * that did not match AA:BB:…:ZZ (so the UI can say which were rejected).
 */
export function parseFingerprints(text) {
  if (typeof text !== "string") return { valid: [], invalid: [] };
  const valid = [];
  const invalid = [];
  for (const raw of text.split(/[\n,]/)) {
    const t = raw.trim().toUpperCase();
    if (t === "") continue;
    if (FP.test(t)) { if (!valid.includes(t)) valid.push(t); }
    else invalid.push(raw.trim());
  }
  return { valid, invalid };
}

/** True for a valid reverse-DNS package/bundle id. */
export function isPackageId(s) {
  return typeof s === "string" && PKG.test(s.trim());
}

/** True for a 10-char upper-alnum Apple Team ID. */
export function isTeamId(s) {
  return typeof s === "string" && /^[A-Z0-9]{10}$/.test(s.trim());
}

/**
 * Android Digital Asset Links. null when the package or the fingerprints are
 * missing (the route handler then 404s). `fingerprints` is a string[] (valid,
 * upper-hex) — e.g. parseFingerprints(stored).valid.
 */
export function assetlinksFor({ androidPackage, fingerprints } = {}) {
  const pkg = typeof androidPackage === "string" ? androidPackage.trim() : "";
  const fps = Array.isArray(fingerprints) ? fingerprints.filter((f) => FP.test(f)) : [];
  if (!PKG.test(pkg) || fps.length === 0) return null;
  return [{
    relation: ["delegate_permission/common.handle_all_urls"],
    target: { namespace: "android_app", package_name: pkg, sha256_cert_fingerprints: fps },
  }];
}

/**
 * Apple App Site Association. null when the Team ID or bundle id is missing.
 */
export function aasaFor({ teamId, bundleId } = {}) {
  const team = typeof teamId === "string" ? teamId.trim() : "";
  const bundle = typeof bundleId === "string" ? bundleId.trim() : "";
  if (!/^[A-Z0-9]{10}$/.test(team) || !PKG.test(bundle)) return null;
  const appID = `${team}.${bundle}`;
  return {
    applinks: { apps: [], details: [{ appID, paths: ["*"] }] },
    webcredentials: { apps: [appID] },
  };
}
