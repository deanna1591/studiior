// Decision 93 amendment — resolve a Claude post-edit into the result the edit
// route returns. Pure (no Next, no fetch), so `node --test` exercises the photo
// fallback. The route calls editResult(parseBrandSpec(reply), { photoPath, current }).
//
//  - spec present: a normal edit. If a photo was uploaded, FORCE background_image
//    to the path (the model cannot drop or rename it) and lift a "none" treatment.
//  - spec null but a photo WAS uploaded: the photo always applies — return the
//    current spec with the photo as a full-bleed background (overlay 0.85) and a
//    note that the worded change didn't land. The edit still counts (the run was
//    already consumed at the gate).
//  - spec null and no photo: ok false (the route refuses with the recorded line).

export function editResult(spec, { photoPath = null, current = null } = {}) {
  if (spec) {
    if (photoPath) {
      spec.background_image = photoPath;
      if (spec.background_treatment === "none") spec.background_treatment = "full";
    }
    return { ok: true, spec };
  }
  if (photoPath && current) {
    return {
      ok: true,
      spec: { ...current, background_image: photoPath, background_treatment: "full", overlay_strength: 0.85 },
      note: "Photo applied. The other change didn't go through.",
    };
  }
  return { ok: false };
}
