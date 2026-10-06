import { test } from "node:test";
import assert from "node:assert/strict";
import { howYouPayCopy } from "../lib/pay-copy.mjs";

test("provider connected -> online copy (GCash/Maya, confirmed straight away)", () => {
  const c = howYouPayCopy({ providerConnected: true, studioName: "Reform" });
  assert.equal(c.title, "Paying Reform");
  assert.match(c.body, /GCash, Maya or a card/);
  assert.match(c.body, /confirmed straight away/);
  assert.match(c.body, /pay at the desk/);
});
test("no provider -> desk copy (cash, bank transfer, card in person)", () => {
  const c = howYouPayCopy({ providerConnected: false, studioName: "Reform" });
  assert.match(c.body, /takes payment at the desk — cash, bank transfer, or a card/);
  assert.doesNotMatch(c.body, /GCash/);
});
