# Stripe integration: remaining setup

My Screen Cam is sold through **hosted Stripe Checkout with Managed Payments**, so Stripe is the merchant of record and
handles VAT and sales tax. This file is the checklist for finishing the Stripe side. The wider plan (licence keys,
watermark, thanks page, webhook) is in [docs/licensing-plan.md](docs/licensing-plan.md).

## Values to Replace

The following values are placeholders and must be updated before going live.

**Files containing placeholders:**
- [apps/web/src/app/api/checkout/route.ts](apps/web/src/app/api/checkout/route.ts)

| Field | Current Value | What to Set |
|-------|--------------|-------------|
| mode | payment | Keep `payment`: My Screen Cam is a one-time purchase. |
| success_url | `{origin}/thanks?session_id={CHECKOUT_SESSION_ID}` | Already the planned URL, built from the request's origin. The `/thanks` page doesn't exist yet (it shows the licence key; plan §5), so until it's built customers land on a 404 after paying. Keep `{CHECKOUT_SESSION_ID}`. |
| cancel_url | `{origin}/` | The home page. Change it if you want a different page. |
| line_items[].price | `price_...` | The Price ID of the My Screen Cam product (see Setup step 3), from https://dashboard.stripe.com/prices. |

## Configured Parameters

These parameters were configured in Checkout Studio and are already set correctly.

**Files containing these parameters:**
- [apps/web/src/app/api/checkout/route.ts](apps/web/src/app/api/checkout/route.ts)

| Parameter | Value |
|-----------|-------|
| ui_mode | `hosted_page` (stripe-node 22.6.2 is installed; `hosted_page` needs 21.0.0 or later) |
| billing_address_collection | `auto` |
| phone_number_collection | `{ enabled: false }` |
| allow_promotion_codes | `false` |
| submit_type | `auto` |
| saved_payment_method_options | `{ payment_method_save: "enabled" }` |
| integration_identifier | `hosted_web_0001` |
| origin_context | `web` |
| managed_payments | `{ enabled: true }` (**replaces Checkout Studio's `automatic_tax: { enabled: true }`**, at your request) |

Checkout Studio asked for `automatic_tax`. Stripe rejects it with Managed Payments, which calculates and pays the tax
itself, so it's left out. `payment_method_collection` (`always`) only applies to subscriptions, so it isn't sent
either.

## Setup

1. **Turn on Managed Payments**: https://dashboard.stripe.com/settings/managed-payments.
   - Accept the Managed Payments terms of service.
   - Confirm your business country is eligible: https://docs.stripe.com/payments/managed-payments/eligibility.
   - Do this in test mode first; everything below repeats in live mode at the end.
2. **Check the tax setting**: in https://dashboard.stripe.com/settings/tax, choose whether prices include tax. By
   default Managed Payments **adds tax on top**. A price can override this with its own `tax_behavior`.
3. **Create the product**: https://dashboard.stripe.com/products.
   - Name: **My Screen Cam**.
   - **Product tax code**: pick one labelled *Eligible for Managed Payments* (downloadable software).
   - One one-time price of **£9.99 GBP**, tax behaviour **inclusive**, so UK buyers pay exactly £9.99.
   - Add a **USD currency option of $9.99** on that price, tax behaviour **exclusive** (the US norm: sales tax is
     added at checkout).
   - Adaptive Pricing is always on with Managed Payments, so buyers in other countries see a converted local price.
   - Copy the Price ID (`price_…`) into `line_items` in the checkout route.
4. **API key**: create a restricted key with write access to **Checkout Sessions** only
   (https://dashboard.stripe.com/test/apikeys).
   - Locally: copy [apps/web/.env.example](apps/web/.env.example) to `apps/web/.env.local` (git-ignored) and set
     `STRIPE_SECRET_KEY`.
   - Deployed: set `STRIPE_SECRET_KEY` in the host's environment variables. Use test keys for preview deployments and
     live keys for production.
   - The route doesn't pin an API version, so it uses the one stripe-node 22.6.2 is built for. That meets Managed
     Payments' minimum of `2025-03-31.basil`.
5. **Buy button**: point the site's Buy button at the route with a form, since it only accepts POST:
   `<form action="/api/checkout" method="POST"><button type="submit">Buy — £9.99</button></form>`.

No publishable key is needed: hosted Checkout redirects from the server.

## New files

```
apps/web/
  .env.example                   documents STRIPE_SECRET_KEY
  src/app/api/checkout/route.ts  POST: creates the Checkout Session, 303-redirects to Stripe
```
`stripe` (22.6.2) was added to `apps/web/package.json`.

## How it works

1. The customer clicks Buy. The form POSTs to `/api/checkout`.
2. The route creates a Checkout Session (Managed Payments on) and redirects to Stripe's hosted page.
3. Stripe shows the local price and tax, takes payment, and sends the receipt. Managed Payments handles invoicing and
   confirmation emails.
4. Stripe redirects to `/thanks?session_id=…`. Cancelling returns to the home page.
5. Still to build (plan §5): the `/thanks` page, and a webhook for `checkout.session.completed` that signs and emails
   the licence key.

If `STRIPE_SECRET_KEY` isn't set, the route answers `503 Checkout isn't configured.`

## Testing

- Run `mise run web`, click Buy (or `curl -i -X POST http://localhost:3000/api/checkout`) and follow the redirect.
- **Cards** (any future expiry, any CVC, any postcode):
  - `4242 4242 4242 4242`: succeeds.
  - `4000 0025 0000 3155`: asks for 3D Secure.
  - `4000 0000 0000 9995`: declined (insufficient funds).
  - More: https://docs.stripe.com/testing.
- Try different billing addresses (a UK postcode, a US ZIP, an EU address) to see tax calculated per country.
- Test mode doesn't send receipt emails automatically. Open the payment in the Dashboard and use **Send receipt** to
  preview one.
- Payments appear at https://dashboard.stripe.com/test/payments, with the tax Managed Payments calculated.

## Next steps

- Build the `/thanks` page and the fulfilment webhook (licence keys): [docs/licensing-plan.md](docs/licensing-plan.md) §5.
  - The webhook will need `STRIPE_WEBHOOK_SECRET`.
  - Test locally with `stripe listen --forward-to localhost:3000/api/stripe/webhook`.
- Add the Buy button and the price to the site (`apps/web/src/lib/site.ts`, hero, closing section, FAQ).
- Go live: repeat Setup steps 1–4 in live mode, set the live key in the production environment, and make one real
  purchase.

## Resources

- Stripe support: https://support.stripe.com
- Stripe MCP server (lets an agent query your Stripe account): https://docs.stripe.com/mcp
- Managed Payments with Checkout: https://docs.stripe.com/payments/managed-payments/update-checkout
