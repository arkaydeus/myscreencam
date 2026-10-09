# Checkout launch setup

The site has a Buy form, a hosted Checkout route, a paid-session confirmation page that shows a signed licence key,
and a signed Stripe webhook that emails the same key through Shipmail, from the `info@myscreen.cam` mailbox. The route returns 503 until every required value
is configured and `CHECKOUT_ENABLED=true`. Stripe failures return a controlled 502 and log the Stripe type, code and
request ID server-side.

Copy `.env.example` to `.env` in the repo root for test mode (`apps/web/next.config.ts` loads it), or set the values on the
hosting service:

- `STRIPE_SECRET_KEY`: restricted key with Checkout Sessions create/read access.
- `STRIPE_PRICE_ID`: the actual one-time Price ID for My Screen Cam. No price is hard-coded in the route.
- `STRIPE_WEBHOOK_SECRET`: signing secret for `/api/stripe/webhook`.
- `LICENCE_SIGNING_KEY`: base64 of an Ed25519 PKCS#8 DER private key. Back up the production key securely.
- `SHIPMAIL_API_KEY_TEST` and `SHIPMAIL_API_KEY`: Shipmail keys with only `messages:send`, limited to the sending
  mailbox. Development, tests and `next build` use the `sm_test_` key, which simulates sends and delivers nothing.
  Production uses the `sm_live_` key, with no fallback between them. A preview deployment is a production build, so give
  it a test key as `SHIPMAIL_API_KEY`.
- `LICENCE_EMAIL_FROM`: the Shipmail mailbox licence emails are sent from, as an address or `Name <address>` (for example
  `My Screen Cam <info@myscreen.cam>`). Checkout stays off while it isn't a valid address.
- `CHECKOUT_ENABLED`: leave `false` until the app accepts signed keys and test purchases pass end to end.

Create the product and price in [Stripe Dashboard](https://dashboard.stripe.com/products) and configure
[Managed Payments](https://dashboard.stripe.com/settings/managed-payments) before enabling Checkout. The current
intent is a one-time £9.99 GBP price with a $9.99 USD currency option; verify the live Stripe price before adding
that amount to site copy.

Register `https://<site>/api/stripe/webhook` in Stripe for `checkout.session.completed` and
`checkout.session.async_payment_succeeded`. Webhook retries use a deterministic licence and a session-based Shipmail
idempotency key. In test mode, make a payment, confirm `/thanks` displays the key and the email arrives, then test an
unpaid or invalid webhook. The app's key verification and activation described in `docs/licensing-plan.md` must ship
before `CHECKOUT_ENABLED` is set to `true` for real customers.
