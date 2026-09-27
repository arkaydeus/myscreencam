import { generateKeyPairSync } from "node:crypto";

import { describe, expect, test } from "bun:test";

import { handleCheckout } from "../src/lib/checkout";

const request = new Request("https://myscreen.cam/api/checkout", { method: "POST" });
const configured = {
  CHECKOUT_ENABLED: "true",
  STRIPE_SECRET_KEY: "sk_test_example",
  STRIPE_PRICE_ID: "price_123abc",
  LICENCE_SIGNING_KEY: generateKeyPairSync("ed25519")
    .privateKey.export({ format: "der", type: "pkcs8" })
    .toString("base64"),
  STRIPE_WEBHOOK_SECRET: "whsec_example",
  RESEND_API_KEY: "re_example",
  LICENCE_EMAIL_FROM: "licences@myscreen.cam",
};

describe("checkout", () => {
  test("unconfigured checkout does not call Stripe", async () => {
    let called = false;
    const response = await handleCheckout(
      request,
      async () => {
        called = true;
        return { url: "https://checkout.stripe.com/a" };
      },
      {},
    );
    expect(response.status).toBe(503);
    expect(called).toBe(false);
  });

  test("a malformed signing key never opens paid Checkout", async () => {
    let called = false;
    const response = await handleCheckout(
      request,
      async () => {
        called = true;
        return { url: "https://checkout.stripe.com/a" };
      },
      { ...configured, LICENCE_SIGNING_KEY: "invalid" },
    );
    expect(response.status).toBe(503);
    expect(called).toBe(false);
  });

  test("a configured purchase creates a hosted session and redirects", async () => {
    const response = await handleCheckout(
      request,
      async (options) => {
        expect(options.mode).toBe("payment");
        expect(options.managed_payments).toEqual({ enabled: true });
        expect(options.line_items).toEqual([{ price: "price_123abc", quantity: 1 }]);
        expect(options.success_url).toBe(
          "https://myscreen.cam/thanks?session_id={CHECKOUT_SESSION_ID}",
        );
        expect(options.cancel_url).toBe("https://myscreen.cam/");
        return { url: "https://checkout.stripe.com/a" };
      },
      configured,
    );
    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe("https://checkout.stripe.com/a");
  });

  test("a missing Checkout URL is a controlled error", async () => {
    const response = await handleCheckout(request, async () => ({ url: null }), configured);
    expect(response.status).toBe(502);
  });

  test("a Stripe failure is a controlled error", async () => {
    const original = console.error;
    console.error = () => {};
    try {
      const response = await handleCheckout(
        request,
        async () => {
          throw {
            type: "StripeInvalidRequestError",
            code: "resource_missing",
            requestId: "req_123",
          };
        },
        configured,
      );
      expect(response.status).toBe(502);
      expect(await response.text()).not.toContain("resource_missing");
    } finally {
      console.error = original;
    }
  });
});
