// The printed studio QR encodes the member-app URL that opens the check-in
// screen. Pure, so the print view (staff side) and a node test agree.
export function checkinPath(slug) {
  return `/checkin/${slug}`;
}
export function checkinUrl(origin, slug) {
  return `${String(origin).replace(/\/+$/, "")}${checkinPath(slug)}`;
}
