import type Stripe from "stripe";

import { isValidSigningKey } from "./licence";

export type CreateSession = (
  options: Stripe.Checkout.SessionCreateParams,
) => Promise<Pick<Stripe.Checkout.Session, "url">>;

export async function handleCheckout(
  request: Request,
  createSession: CreateSession,
  config: Record<string, string | undefined> = process.env,
): Promise<Response> {
  if (!isCheckoutReady(config)) {
    return new Response("Checkout isn't configured yet.", { status: 503 });
  }
  const price = config.STRIPE_PRICE_ID!;
  const origin = new URL(request.url).origin;
  try {
    const session = await createSession({
      ui_mode: "hosted_page",
      mode: "payment",
      billing_address_collection: "auto",
      phone_number_collection: { enabled: false },
      managed_payments: { enabled: true },
      allow_promotion_codes: false,
      submit_type: "auto",
      saved_payment_method_options: { payment_method_save: "enabled" },
      integration_identifier: "hosted_web_0001",
      origin_context: "web",
      line_items: [{ price, quantity: 1 }],
      success_url: `${origin}/thanks?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${origin}/`,
    });
    if (!session.url) return new Response("Checkout is temporarily unavailable.", { status: 502 });
    return Response.redirect(session.url, 303);
  } catch (error) {
    const stripeError = error as { type?: string; code?: string; requestId?: string };
    console.error("Checkout session failed", {
      type: stripeError.type,
      code: stripeError.code,
      requestId: stripeError.requestId,
    });
    return new Response("Checkout is temporarily unavailable. Please try again later.", {
      status: 502,
    });
  }
}

export function isCheckoutReady(config: Record<string, string | undefined> = process.env): boolean {
  const price = config.STRIPE_PRICE_ID;
  return (
    config.CHECKOUT_ENABLED === "true" &&
    !!config.STRIPE_SECRET_KEY &&
    !!price &&
    /^price_[A-Za-z0-9]+$/.test(price) &&
    !!config.LICENCE_SIGNING_KEY &&
    isValidSigningKey(config.LICENCE_SIGNING_KEY) &&
    !!config.STRIPE_WEBHOOK_SECRET &&
    !!config.RESEND_API_KEY &&
    !!config.LICENCE_EMAIL_FROM
  );
}
