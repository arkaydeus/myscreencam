import { Stripe } from "stripe";

import { licenceForSession } from "@/lib/licence";

export async function POST(request: Request) {
  const {
    STRIPE_SECRET_KEY,
    STRIPE_WEBHOOK_SECRET,
    LICENCE_SIGNING_KEY,
    RESEND_API_KEY,
    LICENCE_EMAIL_FROM,
  } = process.env;
  if (
    !STRIPE_SECRET_KEY ||
    !STRIPE_WEBHOOK_SECRET ||
    !LICENCE_SIGNING_KEY ||
    !RESEND_API_KEY ||
    !LICENCE_EMAIL_FROM
  ) {
    return new Response("Fulfilment isn't configured.", { status: 503 });
  }
  const signature = request.headers.get("stripe-signature");
  if (!signature) return new Response("Missing signature.", { status: 400 });
  const stripe = new Stripe(STRIPE_SECRET_KEY);
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(
      await request.text(),
      signature,
      STRIPE_WEBHOOK_SECRET,
    );
  } catch {
    return new Response("Invalid signature.", { status: 400 });
  }
  if (
    event.type !== "checkout.session.completed" &&
    event.type !== "checkout.session.async_payment_succeeded"
  ) {
    return new Response("OK");
  }
  const session = event.data.object as Stripe.Checkout.Session;
  if (session.payment_status !== "paid") return new Response("OK");
  try {
    const key = licenceForSession(session, LICENCE_SIGNING_KEY);
    const email = session.customer_details?.email;
    if (!email) throw new Error("Paid session has no email");
    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${RESEND_API_KEY}`,
        "Content-Type": "application/json",
        "Idempotency-Key": `myscreencam-licence-${session.id}`,
      },
      body: JSON.stringify({
        from: LICENCE_EMAIL_FROM,
        to: [email],
        subject: "Your My Screen Cam licence",
        text: `Thanks for buying My Screen Cam. Your licence key is:\n\n${key}\n\nKeep this email so you can activate again later.`,
      }),
    });
    if (!response.ok) throw new Error(`Email service returned ${response.status}`);
    return new Response("OK");
  } catch (error) {
    console.error("Licence fulfilment failed", { eventId: event.id, sessionId: session.id, error });
    return new Response("Fulfilment failed; retry required.", { status: 500 });
  }
}
