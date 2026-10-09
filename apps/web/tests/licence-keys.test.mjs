import { createPrivateKey, createPublicKey } from "node:crypto";

import { expect, test } from "bun:test";

import { generateLicenceKeypair, setEnvValue } from "../scripts/licence-keys";

test("a generated keypair is Ed25519 and its public half is the raw 32 bytes of the private key's", () => {
  const pair = generateLicenceKeypair();
  const privateKey = createPrivateKey({
    key: Buffer.from(pair.private, "base64"),
    format: "der",
    type: "pkcs8",
  });
  expect(privateKey.asymmetricKeyType).toBe("ed25519");
  const raw = Buffer.from(createPublicKey(privateKey).export({ format: "jwk" }).x, "base64url");
  expect(Buffer.from(pair.public, "base64")).toEqual(raw);
  expect(generateLicenceKeypair().private).not.toBe(pair.private);
});

test("setEnvValue replaces one line, appends when missing, and leaves everything else alone", () => {
  const env = "# keep me\nA=1\nLICENCE_SIGNING_KEY=old\nB=two words\n";
  expect(setEnvValue(env, "LICENCE_SIGNING_KEY", "new")).toBe(
    "# keep me\nA=1\nLICENCE_SIGNING_KEY=new\nB=two words\n",
  );
  expect(setEnvValue("A=1\n", "LICENCE_SIGNING_KEY", "new")).toBe("A=1\nLICENCE_SIGNING_KEY=new\n");
  expect(setEnvValue("A=1", "LICENCE_SIGNING_KEY", "new")).toBe("A=1\nLICENCE_SIGNING_KEY=new\n");
  expect(setEnvValue("", "LICENCE_SIGNING_KEY", "new")).toBe("LICENCE_SIGNING_KEY=new\n");
});

test("setEnvValue copes with values containing $ and regex replacement patterns", () => {
  expect(setEnvValue("K=old\n", "K", "a$&b$1")).toBe("K=a$&b$1\n");
});

test("setEnvValue doesn't touch a key that merely starts the same way", () => {
  const env = "LICENCE_SIGNING_KEY_OLD=keep\n";
  expect(setEnvValue(env, "LICENCE_SIGNING_KEY", "new")).toBe(
    "LICENCE_SIGNING_KEY_OLD=keep\nLICENCE_SIGNING_KEY=new\n",
  );
});
