import { generateKeyPairSync } from "node:crypto";

export type LicenceKeypair = {
  /** PKCS#8 DER, base64: the site's `LICENCE_SIGNING_KEY`. Never commit it. */
  private: string;
  /** The raw 32 bytes, base64: an entry in the app's `MSC_LICENCE_PUBLIC_KEYS`. Safe to publish. */
  public: string;
};

export function generateLicenceKeypair(): LicenceKeypair {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  return {
    private: privateKey.export({ format: "der", type: "pkcs8" }).toString("base64"),
    public: Buffer.from(publicKey.export({ format: "jwk" }).x!, "base64url").toString("base64"),
  };
}

/** Sets `KEY=value` in .env text: replaces the first existing line, or appends one. Other lines are untouched. */
export function setEnvValue(text: string, key: string, value: string): string {
  const line = `${key}=${value}`;
  const existing = new RegExp(`^${key}=.*$`, "m");
  if (existing.test(text)) return text.replace(existing, () => line);
  return `${text}${text === "" || text.endsWith("\n") ? "" : "\n"}${line}\n`;
}
