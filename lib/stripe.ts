import Stripe from "stripe";

/**
 * The platform's Stripe client.
 *
 * One secret key, used two ways. Calls made ON BEHALF OF a studio pass
 * `stripeAccount`, which is what makes a charge land in the studio's own
 * balance rather than ours — Connect Standard with direct charges, no
 * application fee, and money that never touches Studiior.
 *
 * The key is read from the environment here rather than from Vault: this runs
 * in the Next.js process, which has no database session at the moment it needs
 * to construct the client. The database keeps its own copy for the webhook
 * path, which does have one.
 */
export function stripe(): Stripe {
  const key = process.env.STRIPE_SECRET_KEY;
  if (!key) {
    // A clear refusal rather than a crash three frames deep in the SDK.
    throw new Error(
      "STRIPE_SECRET_KEY is not set. Payments are off until it is. " +
      "It is deliberately not in the repo.",
    );
  }
  if (!key.startsWith("sk_test_")) {
    // V1 is test mode throughout. A live key here would move real money on a
    // codebase whose billing has never been run against a real card.
    throw new Error("Refusing to start with a non-test Stripe key: V1 is test mode only.");
  }
  // No apiVersion override: the SDK pins the version its types were
  // generated against, and naming a different one here type-checks as a lie.
  return new Stripe(key);
}

/** A client acting as the studio, for Checkout and subscriptions. */
export function stripeFor(connectedAccountId: string): Stripe {
  stripe();  // the same key and test-mode checks, before we act as anybody
  return new Stripe(process.env.STRIPE_SECRET_KEY!, { stripeAccount: connectedAccountId });
}
