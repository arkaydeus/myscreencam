import { generateKeyPairSync, verify } from "node:crypto";

import { expect, test } from "bun:test";
import { Stripe } from "stripe";

import { POST } from "../src/app/api/stripe/webhook/route";
import { licenceForSession } from "../src/lib/licence";

const { privateKey, publicKey } = generateKeyPairSync("ed25519");
const signingKey = privateKey.export({ format: "der", type: "pkcs8" }).toString("base64");
const session = {
  id: "cs_test_purchase",
  object: "checkout.session",
  created: 1_790_000_000,
  payment_status: "paid",
  customer_details: { email: "buyer@example.com" },
};
const secret = "whsec_test";

async function signedRequest(data) {
  const payload = JSON.stringify(data);
  const signature = await Stripe.webhooks.generateTestHeaderStringAsync({ payload, secret });
  return new Request("https://myscreen.cam/api/stripe/webhook", {
    method: "POST",
    headers: { "stripe-signature": signature },
    body: payload,
  });
}

function event(paymentStatus = "paid") {
  return {
    id: "evt_purchase",
    object: "event",
    type: "checkout.session.completed",
    data: { object: { ...session, payment_status: paymentStatus } },
  };
}

async function configured(run) {
  const keys = {
    STRIPE_SECRET_KEY: "sk_test_example",
    STRIPE_WEBHOOK_SECRET: secret,
    LICENCE_SIGNING_KEY: signingKey,
    RESEND_API_KEY: "re_test",
    LICENCE_EMAIL_FROM: "licences@myscreen.cam",
  };
  const previous = Object.fromEntries(Object.keys(keys).map((key) => [key, process.env[key]]));
  try {
    Object.assign(process.env, keys);
    await run();
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

test("licence is deterministic and verifiable with its public key", () => {
  const licence = licenceForSession(session, signingKey);
  expect(licenceForSession(session, signingKey)).toBe(licence);
  const [prefix, payload, signature] = licence.split(".");
  expect(prefix).toBe("MSC1");
  expect(JSON.parse(Buffer.from(payload, "base64url")).email).toBe("buyer@example.com");
  expect(
    verify(null, Buffer.from(payload, "base64url"), publicKey, Buffer.from(signature, "base64url")),
  ).toBe(true);
  expect(() => licenceForSession({ ...session, payment_status: "unpaid" }, signingKey)).toThrow();
});

test("webhook verifies its signature and emails one paid licence", async () => {
  await configured(async () => {
    const originalFetch = globalThis.fetch;
    const calls = [];
    globalThis.fetch = async (url, options) => {
      calls.push({ url, options });
      return new Response('{"id":"email_1"}', { status: 200 });
    };
    try {
      expect(
        (
          await POST(
            new Request("https://myscreen.cam/api/stripe/webhook", { method: "POST", body: "{}" }),
          )
        ).status,
      ).toBe(400);
      const badSignature = new Request("https://myscreen.cam/api/stripe/webhook", {
        method: "POST",
        headers: { "stripe-signature": "bad" },
        body: "{}",
      });
      expect((await POST(badSignature)).status).toBe(400);
      expect((await POST(await signedRequest(event("unpaid")))).status).toBe(200);
      expect(calls.length).toBe(0);
      expect((await POST(await signedRequest(event()))).status).toBe(200);
      expect(calls.length).toBe(1);
      expect(calls[0].options.headers["Idempotency-Key"]).toBe(
        "myscreencam-licence-cs_test_purchase",
      );
      expect(JSON.parse(calls[0].options.body).text).toContain(
        licenceForSession(session, signingKey),
      );
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});
