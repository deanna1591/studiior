// Decision 35 FIX C — the member "How you pay" copy, driven by whether the
// studio has a live online payment provider (the SAME flag the Buy pages use to
// decide whether online checkout is offered). Pure, node-tested.
export function howYouPayCopy({ providerConnected = false, studioName = "the studio" } = {}) {
  if (providerConnected) {
    return {
      title: `Paying ${studioName}`,
      body: "Pay in the app with GCash, Maya or a card — plans and drop-ins you buy here are confirmed straight away. You can also pay at the desk.",
    };
  }
  return {
    title: `Paying ${studioName}`,
    body: `${studioName} takes payment at the desk — cash, bank transfer, or a card in person. Book your class or reserve your plan in the app, then settle up when you come in.`,
  };
}
