import { createHash, createPrivateKey, sign } from "node:crypto";

import type Stripe from "stripe";

function base32(bytes: Buffer): string {
  const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
  let bits = 0;
  let value = 0;
  let result = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      result += alphabet[(value >>> (bits -= 5)) & 31];
    }
  }
  if (bits) result += alphabet[(value << (5 - bits)) & 31];
  return result;
}

export function isValidSigningKey(value: string): boolean {
  try {
    return (
      createPrivateKey({ key: Buffer.from(value, "base64"), format: "der", type: "pkcs8" })
        .asymmetricKeyType === "ed25519"
    );
  } catch {
    return false;
  }
}

export function licenceForSession(session: Stripe.Checkout.Session, signingKey: string): string {
  if (session.payment_status !== "paid") throw new Error("Session is not paid");
  const email = session.customer_details?.email;
  if (!email) throw new Error("Paid session has no customer email");
  const payload = Buffer.from(
    JSON.stringify({
      v: 1,
      id: `lic_${base32(createHash("sha256").update(session.id).digest()).slice(0, 16)}`,
      email,
      product: "myscreencam",
      issued: new Date(session.created * 1000).toISOString().slice(0, 10),
    }),
  );
  const key = createPrivateKey({
    key: Buffer.from(signingKey, "base64"),
    format: "der",
    type: "pkcs8",
  });
  return `MSC1.${payload.toString("base64url")}.${sign(null, payload, key).toString("base64url")}`;
}
