import { createPublicKey, verify } from "node:crypto";
import { readFileSync } from "node:fs";

import { describe, expect, test } from "bun:test";

import { generateLicenceKeypair } from "../scripts/licence-keys";
import { licenceForSession } from "../src/lib/licence";

// The vectors hold only public keys and signed licence keys. Nothing here needs, or has, a signing key: the site
// signs with a throwaway key made at test time.
const vectors = JSON.parse(
  readFileSync(new URL("../../../licence/test-vectors.json", import.meta.url)),
);

// Ed25519 SPKI is a fixed 12-byte header followed by the raw 32-byte public key (what the app stores).
const spki = (raw) =>
  createPublicKey({
    key: Buffer.concat([
      Buffer.from("302a300506032b6570032100", "hex"),
      Buffer.from(raw, "base64"),
    ]),
    format: "der",
    type: "spki",
  });

const paid = ({ id, created, email }) => ({
  id,
  created,
  object: "checkout.session",
  payment_status: "paid",
  customer_details: { email },
});

/** A second, independent implementation of the verifier's rules, in Node, to check the vectors are self-consistent. */
function judge({ key, publicKeys, revoked }) {
  const parts = key.replace(/\s+/g, "").split(".");
  const base64url = /^[A-Za-z0-9_-]+$/;
  if (parts.length !== 3 || parts[0] !== "MSC1") return "malformed";
  if (!base64url.test(parts[1]) || !base64url.test(parts[2])) return "malformed";
  const payload = Buffer.from(parts[1], "base64url");
  const signature = Buffer.from(parts[2], "base64url");
  if (signature.length !== 64) return "malformed";
  let body;
  try {
    body = JSON.parse(payload.toString());
  } catch {
    return "malformed";
  }
  if (body?.v !== 1) return "malformed";
  for (const field of ["id", "email", "product", "issued"]) {
    if (typeof body[field] !== "string") return "malformed";
  }
  const trusted = publicKeys.map((name) => spki(vectors.publicKeys[name]));
  if (!trusted.some((publicKey) => verify(null, payload, publicKey, signature))) {
    return "badSignature";
  }
  if (body.product !== "myscreencam") return "wrongProduct";
  if (revoked.includes(body.id)) return "revoked";
  return "valid";
}

test("the vectors file has public keys and every kind of verdict, and no signing key", () => {
  const { signer, other } = vectors.publicKeys;
  expect(Buffer.from(signer, "base64")).toHaveLength(32);
  expect(Buffer.from(other, "base64")).toHaveLength(32);
  expect(signer).not.toBe(other);
  expect(Object.keys(vectors.publicKeys).toSorted()).toEqual(["other", "signer"]);
  expect(vectors.cases.length).toBeGreaterThanOrEqual(20);
  expect(new Set(vectors.cases.map((c) => c.expect))).toEqual(
    new Set(["valid", "malformed", "badSignature", "wrongProduct", "revoked"]),
  );
});

describe("an independent Node verifier agrees with every vector", () => {
  test.each(vectors.cases.map((c) => [c.name, c]))("%s", (_name, vector) => {
    expect(judge(vector)).toBe(vector.expect);
  });
});

test("the committed signatures verify under the committed public key", () => {
  for (const { key } of vectors.sessions) {
    const [prefix, payload, signature] = key.split(".");
    expect(prefix).toBe("MSC1");
    expect(
      verify(
        null,
        Buffer.from(payload, "base64url"),
        spki(vectors.publicKeys.signer),
        Buffer.from(signature, "base64url"),
      ),
    ).toBe(true);
  }
});

test("the signer's payload matches the committed vectors, so the format can't drift", () => {
  const throwaway = generateLicenceKeypair();
  for (const session of vectors.sessions) {
    const fresh = licenceForSession(paid(session), throwaway.private).split(".");
    const [prefix, payload] = session.key.split(".");
    expect(fresh[0]).toBe(prefix);
    expect(fresh[1]).toBe(payload);
    // The signature differs (a different key) but is well-formed and verifies under that key.
    expect(Buffer.from(fresh[2], "base64url")).toHaveLength(64);
    expect(
      verify(
        null,
        Buffer.from(fresh[1], "base64url"),
        spki(throwaway.public),
        Buffer.from(fresh[2], "base64url"),
      ),
    ).toBe(true);
  }
});

test("a licence key is deterministic for one signing key and about 200 characters", () => {
  const { private: signingKey } = generateLicenceKeypair();
  const session = paid(vectors.sessions[0]);
  const key = licenceForSession(session, signingKey);
  expect(licenceForSession(session, signingKey)).toBe(key);
  expect(key.length).toBeGreaterThan(150);
  expect(key.length).toBeLessThan(260);
});

test("the payload carries only the documented fields", () => {
  const payload = JSON.parse(Buffer.from(vectors.sessions[0].key.split(".")[1], "base64url"));
  expect(Object.keys(payload)).toEqual(["v", "id", "email", "product", "issued"]);
  expect(payload).toMatchObject({ v: 1, product: "myscreencam", email: "jane@example.com" });
  expect(payload.id).toMatch(/^lic_[a-z2-7]{16}$/);
  expect(payload).toEqual(vectors.expectedPayload);
});

test("an unpaid session or one without an email gets no key", () => {
  const { private: signingKey } = generateLicenceKeypair();
  const base = { id: "cs_test_x", created: 1_790_000_000, customer_details: { email: "a@b.co" } };
  expect(() => licenceForSession({ ...base, payment_status: "unpaid" }, signingKey)).toThrow();
  expect(() =>
    licenceForSession({ ...base, payment_status: "paid", customer_details: null }, signingKey),
  ).toThrow();
});
