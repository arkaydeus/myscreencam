import { Stripe } from "stripe";

import { licenceForSession } from "@/lib/licence";
import { sendLicenceEmail, shipmailApiKey } from "@/lib/licence-email";

export async function POST(request: Request) {
  const { STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, LICENCE_SIGNING_KEY, LICENCE_EMAIL_FROM } =
    process.env;
  const shipmailKey = shipmailApiKey();
  if (
    !STRIPE_SECRET_KEY ||
    !STRIPE_WEBHOOK_SECRET ||
    !LICENCE_SIGNING_KEY ||
    !shipmailKey ||
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
    await sendLicenceEmail({
      apiKey: shipmailKey,
      from: LICENCE_EMAIL_FROM,
      to: email,
      licence: key,
      idempotencyKey: `myscreencam-licence-${session.id}`,
    });
    return new Response("OK");
  } catch (error) {
    console.error("Licence fulfilment failed", { eventId: event.id, sessionId: session.id, error });
    return new Response("Fulfilment failed; retry required.", { status: 500 });
  }
}
