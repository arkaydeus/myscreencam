import { Stripe } from "stripe";

import { handleCheckout } from "@/lib/checkout";

export async function POST(request: Request) {
  // handleCheckout validates all fulfilment settings before this client can make a request.
  const secretKey = process.env.STRIPE_SECRET_KEY;
  if (!secretKey) return new Response("Checkout isn't configured yet.", { status: 503 });
  const stripe = new Stripe(secretKey);
  return handleCheckout(request, (options) => stripe.checkout.sessions.create(options));
}
