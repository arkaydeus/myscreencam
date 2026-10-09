// Generates an Ed25519 licence keypair. No private key is ever written inside the repo's tracked files.
//
//   bun scripts/licence-keygen.ts
//       Prints the private key (LICENCE_SIGNING_KEY) and the public key (MSC_LICENCE_PUBLIC_KEYS). Nothing is
//       written to disk. Use this for the production keypair, and back the private key up in a password manager.
//
//   bun scripts/licence-keygen.ts --env ../../.env
//       For development: sets LICENCE_SIGNING_KEY in that (git-ignored) .env file, replacing any existing value,
//       and prints only the public key. The private key is never printed.
import { chmodSync, existsSync, readFileSync, writeFileSync } from "node:fs";

import { generateLicenceKeypair, setEnvValue } from "./licence-keys";

const pair = generateLicenceKeypair();
const flag = process.argv.indexOf("--env");

if (flag === -1) {
  console.log(`LICENCE_SIGNING_KEY=${pair.private}`);
  console.log(`MSC_LICENCE_PUBLIC_KEYS=${pair.public}`);
} else {
  const path = process.argv[flag + 1];
  if (!path) throw new Error("--env needs the path of a .env file");
  const created = !existsSync(path);
  const text = created ? "" : readFileSync(path, "utf8");
  writeFileSync(path, setEnvValue(text, "LICENCE_SIGNING_KEY", pair.private));
  if (created) chmodSync(path, 0o600);
  console.log(`Set LICENCE_SIGNING_KEY in ${path}`);
  console.log(`MSC_LICENCE_PUBLIC_KEYS=${pair.public}`);
}
