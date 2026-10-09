// Builds licence/test-vectors.json: the licence keys that both the website signer (tests/licence.test.mjs)
// and the app's verifier (LicenceTests.swift in MyScreenCamCore) are checked against, so the two can't drift.
//
//   bun scripts/licence-vectors.ts --write    regenerate the file
//
// Every run signs with a fresh throwaway keypair and keeps only its public half in the file. The private half
// exists in memory for the length of the run, so there is no signing key in the repo. Regenerate when the licence
// format changes; the file is otherwise stable.
import { writeFileSync } from "node:fs";

import { licenceForSession, signLicence, type LicencePayload } from "../src/lib/licence";
import { generateLicenceKeypair, type LicenceKeypair } from "./licence-keys";

type Expectation = "valid" | "malformed" | "badSignature" | "wrongProduct" | "revoked";
type Case = {
  name: string;
  key: string;
  publicKeys: string[];
  revoked: string[];
  expect: Expectation;
};

const flip = (text: string) =>
  `${text.slice(0, -2)}${text.endsWith("A") ? "B" : "A"}${text.slice(-1)}`;

export function buildVectors(signer: LicenceKeypair = generateLicenceKeypair()) {
  // A second keypair the app is never told to trust. Only its public half is kept.
  const other = generateLicenceKeypair().public;

  const sessions = [
    { id: "cs_test_a1b2c3d4", created: 1_790_000_000, email: "jane@example.com" },
    { id: "cs_test_e5f6a7b8", created: 1_791_196_439, email: "søren+licence@example.co.uk" },
  ].map((session) => ({
    ...session,
    key: licenceForSession(
      {
        ...session,
        object: "checkout.session",
        payment_status: "paid",
        customer_details: { email: session.email },
      } as never,
      signer.private,
    ),
  }));

  const valid = sessions[0].key;
  const [prefix, payload, signature] = valid.split(".");
  const payloadJSON = JSON.parse(Buffer.from(payload, "base64url").toString()) as LicencePayload;
  const resign = (changes: Partial<LicencePayload>) =>
    signLicence({ ...payloadJSON, ...changes }, signer.private);
  const reencoded = (changes: Partial<LicencePayload>) =>
    Buffer.from(JSON.stringify({ ...payloadJSON, ...changes })).toString("base64url");

  const trusted = ["signer"];
  const cases: Case[] = [
    { name: "valid key", key: valid, publicKeys: trusted, revoked: [], expect: "valid" },
    {
      name: "valid key from the second entry in a rotated key list",
      key: valid,
      publicKeys: ["other", "signer"],
      revoked: [],
      expect: "valid",
    },
    {
      name: "valid key with non-ASCII email",
      key: sessions[1].key,
      publicKeys: trusted,
      revoked: [],
      expect: "valid",
    },
    {
      name: "pasted with surrounding whitespace",
      key: `  \n${valid}\n\t`,
      publicKeys: trusted,
      revoked: [],
      expect: "valid",
    },
    {
      name: "pasted wrapped across lines",
      key: `${valid.slice(0, 60)}\n${valid.slice(60, 120)}\r\n${valid.slice(120)}`,
      publicKeys: trusted,
      revoked: [],
      expect: "valid",
    },
    {
      name: "tampered payload",
      key: `${prefix}.${reencoded({ email: "mallory@example.com" })}.${signature}`,
      publicKeys: trusted,
      revoked: [],
      expect: "badSignature",
    },
    {
      name: "tampered signature",
      key: `${prefix}.${payload}.${flip(signature)}`,
      publicKeys: trusted,
      revoked: [],
      expect: "badSignature",
    },
    {
      name: "signed by a key the app doesn't trust",
      key: valid,
      publicKeys: ["other"],
      revoked: [],
      expect: "badSignature",
    },
    {
      name: "wrong product",
      key: resign({ product: "someotherapp" }),
      publicKeys: trusted,
      revoked: [],
      expect: "wrongProduct",
    },
    {
      name: "revoked licence",
      key: valid,
      publicKeys: trusted,
      revoked: [payloadJSON.id],
      expect: "revoked",
    },
    {
      name: "revoked list for other licences",
      key: valid,
      publicKeys: trusted,
      revoked: ["lic_aaaaaaaaaaaaaaaa"],
      expect: "valid",
    },
    { name: "empty", key: "", publicKeys: trusted, revoked: [], expect: "malformed" },
    { name: "whitespace only", key: " \n ", publicKeys: trusted, revoked: [], expect: "malformed" },
    { name: "garbage", key: "hello world", publicKeys: trusted, revoked: [], expect: "malformed" },
    {
      name: "truncated before the signature",
      key: valid.slice(0, 80),
      publicKeys: trusted,
      revoked: [],
      expect: "malformed",
    },
    {
      name: "signature too short",
      key: `${prefix}.${payload}.${signature.slice(0, 40)}`,
      publicKeys: trusted,
      revoked: [],
      expect: "malformed",
    },
    {
      name: "wrong prefix",
      key: `MSC2.${payload}.${signature}`,
      publicKeys: trusted,
      revoked: [],
      expect: "malformed",
    },
    {
      name: "extra segment",
      key: `${valid}.extra`,
      publicKeys: trusted,
      revoked: [],
      expect: "malformed",
    },
    {
      name: "payload that isn't JSON",
      key: `${prefix}.${Buffer.from("not json").toString("base64url")}.${signature}`,
      publicKeys: trusted,
      revoked: [],
      expect: "malformed",
    },
    {
      name: "unsupported payload version",
      key: resign({ v: 2 }),
      publicKeys: trusted,
      revoked: [],
      expect: "malformed",
    },
    {
      name: "no trusted keys",
      key: valid,
      publicKeys: [],
      revoked: [],
      expect: "badSignature",
    },
  ];

  return {
    note: "Generated by apps/web/scripts/licence-vectors.ts with a throwaway keypair whose private half was discarded. Don't edit by hand.",
    publicKeys: { signer: signer.public, other },
    expectedPayload: payloadJSON,
    sessions,
    cases,
  };
}

if (process.argv.includes("--write")) {
  const file = new URL("../../../licence/test-vectors.json", import.meta.url);
  writeFileSync(file, `${JSON.stringify(buildVectors(), null, 2)}\n`);
  console.log(
    "Wrote licence/test-vectors.json (signed with a throwaway key; its private half was discarded)",
  );
}
