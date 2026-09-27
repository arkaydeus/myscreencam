import { Stripe } from "stripe";

/**
 * Buy button target: creates a Stripe-hosted Checkout Session and redirects to it.
 * Post a form here (`<form action="/api/checkout" method="POST">`). Setup: STRIPE_INTEGRATION_TODO.md.
 */
export async function POST(request: Request) {
  const secretKey = process.env.STRIPE_SECRET_KEY;
  if (!secretKey) {
    return new Response("Checkout isn't configured.", { status: 503 });
  }
  const stripe = new Stripe(secretKey);
  const origin = new URL(request.url).origin;

  const session = await stripe.checkout.sessions.create({
    ui_mode: "hosted_page",
    mode: "payment",
    billing_address_collection: "auto",
    phone_number_collection: { enabled: false },
    // Stripe is the merchant of record and handles tax, so `automatic_tax` must not be sent.
    managed_payments: { enabled: true },
    allow_promotion_codes: false,
    submit_type: "auto",
    saved_payment_method_options: { payment_method_save: "enabled" },
    integration_identifier: "hosted_web_0001",
    origin_context: "web",
    // TODO: placeholder Price ID; see STRIPE_INTEGRATION_TODO.md.
    line_items: [{ price: "price_...", quantity: 1 }],
    success_url: `${origin}/thanks?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${origin}/`,
  });

  if (!session.url) {
    return new Response("Stripe didn't return a Checkout URL.", { status: 502 });
  }
  return Response.redirect(session.url, 303);
}
