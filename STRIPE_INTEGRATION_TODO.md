# Checkout launch setup

The site has a Buy form, a hosted Checkout route, a paid-session confirmation page that shows a signed licence key,
and a signed Stripe webhook that emails the same key through Resend. The route returns 503 until every required value
is configured and `CHECKOUT_ENABLED=true`. Stripe failures return a controlled 502 and log the Stripe type, code and
request ID server-side.

Copy `apps/web/.env.example` to `apps/web/.env.local` for test mode, or set the values on the hosting service:

- `STRIPE_SECRET_KEY`: restricted key with Checkout Sessions create/read access.
- `STRIPE_PRICE_ID`: the actual one-time Price ID for My Screen Cam. No price is hard-coded in the route.
- `STRIPE_WEBHOOK_SECRET`: signing secret for `/api/stripe/webhook`.
- `LICENCE_SIGNING_KEY`: base64 of an Ed25519 PKCS#8 DER private key. Back up the production key securely.
- `RESEND_API_KEY` and `LICENCE_EMAIL_FROM`: API key and verified sender for licence delivery.
- `CHECKOUT_ENABLED`: leave `false` until the app accepts signed keys and test purchases pass end to end.

Create the product and price in [Stripe Dashboard](https://dashboard.stripe.com/products) and configure
[Managed Payments](https://dashboard.stripe.com/settings/managed-payments) before enabling Checkout. The current
intent is a one-time £9.99 GBP price with a $9.99 USD currency option; verify the live Stripe price before adding
that amount to site copy.

Register `https://<site>/api/stripe/webhook` in Stripe for `checkout.session.completed` and
`checkout.session.async_payment_succeeded`. Webhook retries use a deterministic licence and a session-based Resend
idempotency key. In test mode, make a payment, confirm `/thanks` displays the key and the email arrives, then test an
unpaid or invalid webhook. The app's key verification and activation described in `docs/licensing-plan.md` must ship
before `CHECKOUT_ENABLED` is set to `true` for real customers.
