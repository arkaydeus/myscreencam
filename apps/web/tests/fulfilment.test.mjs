import { generateKeyPairSync, verify } from "node:crypto";

import { expect, spyOn, test } from "bun:test";
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
    NODE_ENV: "test",
    STRIPE_SECRET_KEY: "sk_test_example",
    STRIPE_WEBHOOK_SECRET: secret,
    LICENCE_SIGNING_KEY: signingKey,
    SHIPMAIL_API_KEY_TEST: "sm_test_key",
    SHIPMAIL_API_KEY: "sm_live_key",
    LICENCE_EMAIL_FROM: "My Screen Cam <info@myscreen.cam>",
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

test.each([
  ["a non-2xx email response", () => new Response("Unavailable", { status: 503 })],
  ["a network rejection", () => Promise.reject(new Error("Connection lost"))],
])(
  "webhook returns 500 after %s and retries the same licence and idempotency key",
  async (_name, fail) => {
    await configured(async () => {
      const calls = [];
      const fetchSpy = spyOn(globalThis, "fetch").mockImplementation(async (url, options) => {
        calls.push({ url, options });
        return calls.length === 1 ? fail() : new Response('{"id":"email_1"}', { status: 200 });
      });
      const errorSpy = spyOn(console, "error").mockImplementation(() => {});
      try {
        const failed = await POST(await signedRequest(event()));
        expect(failed.status).toBe(500);
        expect(await failed.text()).toBe("Fulfilment failed; retry required.");
        expect((await POST(await signedRequest(event()))).status).toBe(200);
        expect(calls).toHaveLength(2);
        for (const call of calls) {
          expect(call.options.headers["Idempotency-Key"]).toBe(
            "myscreencam-licence-cs_test_purchase",
          );
          expect(JSON.parse(call.options.body).text).toContain(
            licenceForSession(session, signingKey),
          );
        }
        expect(calls[1].options.body).toBe(calls[0].options.body);
      } finally {
        fetchSpy.mockRestore();
        errorSpy.mockRestore();
      }
    });
  },
);

test.each([null, {}])(
  "webhook returns 500 for a paid session without customer email (%j)",
  async (customerDetails) => {
    await configured(async () => {
      const fetchSpy = spyOn(globalThis, "fetch").mockResolvedValue(new Response("OK"));
      const errorSpy = spyOn(console, "error").mockImplementation(() => {});
      try {
        const purchase = event();
        purchase.data.object.customer_details = customerDetails;
        expect((await POST(await signedRequest(purchase))).status).toBe(500);
        expect(fetchSpy).not.toHaveBeenCalled();
      } finally {
        fetchSpy.mockRestore();
        errorSpy.mockRestore();
      }
    });
  },
);

test("delayed payment emails the same signed licence and idempotency key as completed checkout", async () => {
  await configured(async () => {
    const calls = [];
    const fetchSpy = spyOn(globalThis, "fetch").mockImplementation(async (_url, options) => {
      calls.push(options);
      return new Response('{"id":"email_1"}', { status: 200 });
    });
    try {
      expect((await POST(await signedRequest(event("unpaid")))).status).toBe(200);
      expect(calls).toHaveLength(0);
      const delayed = {
        ...event(),
        id: "evt_delayed",
        type: "checkout.session.async_payment_succeeded",
      };
      expect((await POST(await signedRequest(delayed))).status).toBe(200);
      expect((await POST(await signedRequest(event()))).status).toBe(200);
      expect(calls).toHaveLength(2);
      expect(calls[0].headers["Idempotency-Key"]).toBe("myscreencam-licence-cs_test_purchase");
      expect(calls[1].headers["Idempotency-Key"]).toBe(calls[0].headers["Idempotency-Key"]);
      expect(calls[1].body).toBe(calls[0].body);
      const licence = JSON.parse(calls[0].body).text.match(/MSC1\.[\w-]+\.[\w-]+/)[0];
      expect(licence).toBe(licenceForSession(session, signingKey));
      const [, payload, signature] = licence.split(".");
      expect(
        verify(
          null,
          Buffer.from(payload, "base64url"),
          publicKey,
          Buffer.from(signature, "base64url"),
        ),
      ).toBe(true);
    } finally {
      fetchSpy.mockRestore();
    }
  });
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
      expect(calls[0].url).toBe("https://shipmail.to/api/v1/messages");
      expect(calls[0].options.method).toBe("POST");
      expect(calls[0].options.headers.Authorization).toBe("Bearer sm_test_key");
      expect(calls[0].options.headers["Idempotency-Key"]).toBe(
        "myscreencam-licence-cs_test_purchase",
      );
      const message = JSON.parse(calls[0].options.body);
      expect(message.from).toBe("My Screen Cam <info@myscreen.cam>");
      expect(message.to).toEqual(["buyer@example.com"]);
      expect(message.text).toContain(licenceForSession(session, signingKey));
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});
