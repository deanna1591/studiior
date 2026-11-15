// Decision 107: the member and instructor apps show "A new version is ready" when
// a new deploy is live. The client fetches the build id of the deploy that served
// it (the baseline) and polls a lightweight endpoint; a changed id means a new
// version. These pure helpers hold the comparison and the suppressed-screen rule
// so a node test can prove them and the component stays small.

/** A new version is live when both ids are known and they differ. An unknown or
 *  equal id is never a new version (so a failed poll never nags). */
export function isNewVersion(baseline, current) {
  return !!baseline && !!current && baseline !== current;
}

/** The update bar is suppressed, and nothing ever reloads on its own, while the
 *  member is in checkout or mid-form. Keyed on the path: the checkout, reserve,
 *  buy and purchase flows, the profile and waiver forms, and group booking. */
export function isSuppressedPath(pathname) {
  const p = pathname || "";
  return (
    p.includes("/checkout") ||
    p.includes("/reserve") ||
    p.includes("/buy") ||
    p.includes("/purchase") ||
    p.includes("/waiver") ||
    p.includes("/account/profile") ||
    p.includes("/group/")
  );
}
