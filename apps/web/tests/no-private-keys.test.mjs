import { execFileSync } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { expect, test } from "bun:test";

import { generateLicenceKeypair } from "../scripts/licence-keys";

// No private key belongs in git: not a test fixture, not a "development only" key. Signing keys live in the
// git-ignored root .env (or the host's environment). This scans every tracked or not-yet-ignored file.
//
// The patterns are built at run time so this file doesn't contain what it looks for.
const pem = new RegExp(`-----BEGIN (?:[A-Z]+ )?${"PRIVATE"} KEY-----`);
// Every Ed25519 PKCS#8 private key starts with the same 16-byte header, which encodes to the same text.
const ed25519Pkcs8 = Buffer.from("302e020100300506032b657004220420", "hex")
  .toString("base64")
  .slice(0, 21);

export function containsPrivateKey(text) {
  return pem.test(text) || text.includes(ed25519Pkcs8);
}

test("the scanner recognises a private key and ignores a public one", () => {
  const pair = generateLicenceKeypair();
  expect(containsPrivateKey(pair.private)).toBe(true);
  expect(containsPrivateKey(`LICENCE_SIGNING_KEY=${pair.private}\n`)).toBe(true);
  expect(containsPrivateKey(pair.public)).toBe(false);
  expect(containsPrivateKey(`-----BEGIN ${"PRIVATE"} KEY-----\nabc`)).toBe(true);
  expect(containsPrivateKey(`-----BEGIN RSA ${"PRIVATE"} KEY-----\nabc`)).toBe(true);
  expect(containsPrivateKey(`-----BEGIN ${"PUBLIC"} KEY-----\nabc`)).toBe(false);
});

test("no tracked or unignored file contains a private key", () => {
  const root = fileURLToPath(new URL("../../../", import.meta.url));
  let files;
  try {
    files = execFileSync("git", ["-C", root, "ls-files", "-co", "--exclude-standard", "-z"], {
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
    })
      .split("\0")
      .filter(Boolean);
  } catch {
    return; // Not a git checkout (for example an exported tarball): nothing to scan.
  }
  const offenders = [];
  for (const file of files) {
    const path = join(root, file);
    let size;
    try {
      size = statSync(path).size;
    } catch {
      continue; // Listed but deleted in the working tree.
    }
    if (size > 2_000_000) continue;
    const contents = readFileSync(path);
    if (contents.includes(0)) continue; // Binary.
    if (containsPrivateKey(contents.toString("utf8"))) offenders.push(file);
  }
  expect(offenders).toEqual([]);
});
