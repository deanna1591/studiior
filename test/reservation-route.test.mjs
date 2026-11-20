// Decision 103(a) note, 19 Nov 2026: a waived member is routed to the ordinary
// free path and never sees a fee line; the reservation sentences carry no em dash.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { memberFeeCents, freeClassRoute } from "../lib/reservation-route.mjs";

test("feeWaived false with a fee: the member is asked the studio fee and routed to /reserve", () => {
  assert.equal(memberFeeCents({ reservationFeeCents: 50000, feeWaived: false }), 50000);
  assert.equal(freeClassRoute({ reservationFeeCents: 50000, feeWaived: false }), "reserve");
});

test("feeWaived true: no fee and the ordinary free path, whatever the studio charges", () => {
  assert.equal(memberFeeCents({ reservationFeeCents: 50000, feeWaived: true }), 0);
  assert.equal(freeClassRoute({ reservationFeeCents: 50000, feeWaived: true }), "free");
});

test("no studio fee: free either way; bad input never yields a fee", () => {
  assert.equal(freeClassRoute({ reservationFeeCents: 0, feeWaived: false }), "free");
  assert.equal(freeClassRoute({ reservationFeeCents: null, feeWaived: false }), "free");
  assert.equal(memberFeeCents({ reservationFeeCents: -5, feeWaived: false }), 0);
  assert.equal(memberFeeCents({}), 0);
});

test("the reservation sentences and fallback are the recorded ones, with no em dash", () => {
  const src = readFileSync(new URL("../lib/booking-reasons.ts", import.meta.url), "utf8");
  const block = src.slice(src.indexOf("export const GENERIC_FAILURE"));
  assert.match(block, /fee_waived: "Your reservation fee is waived\. Book the class without paying\."/);
  assert.match(block, /not_enabled: "Reservations are not open right now\."/);
  assert.match(block, /not_due: "This class is already booked\. Nothing to pay\."/);
  assert.match(block, /GENERIC_FAILURE = "That didn't work\. Please try again\."/);
  assert.ok(!block.includes("—"), "no em dash in the reservation sentences");
});

test("every member surface that picks free-or-reserve reads memberFeeCents, never the studio fee alone", () => {
  for (const f of ["app/member/book/page.tsx", "app/member/class/[id]/page.tsx",
                   "app/member/@modal/(.)class/[id]/page.tsx", "app/member/page.tsx",
                   "app/member/reserve/[occurrenceId]/page.tsx"]) {
    const s = readFileSync(new URL("../" + f, import.meta.url), "utf8");
    assert.ok(s.includes("settings.memberFeeCents"), f + " reads memberFeeCents");
    assert.ok(!/reservationFeeLabel=\{settings\.reservationFeeCents/.test(s), f + " passes no studio-fee label");
  }
});
