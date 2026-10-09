import { readFileSync } from "node:fs";
import { join } from "node:path";

import { parse, populate } from "dotenv";
import { expand } from "dotenv-expand";

/** Root defaults follow Next.js file precedence; existing host and app values (including empty strings) win. */
export function loadRootEnv(root: string, env: NodeJS.ProcessEnv = process.env): void {
  const mode =
    env.NODE_ENV === "test" ? "test" : env.NODE_ENV === "production" ? "production" : "development";
  const files = [
    `.env.${mode}.local`,
    ...(mode === "test" ? [] : [".env.local"]),
    `.env.${mode}`,
    ".env",
  ];
  for (const file of files) {
    let contents: Buffer;
    try {
      contents = readFileSync(join(root, file));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") continue;
      throw error;
    }
    const parsed = parse(contents);
    // Only expand missing defaults, so even an empty host/app value remains authoritative.
    for (const key of Object.keys(parsed)) {
      if (env[key] !== undefined) delete parsed[key];
    }
    const expansionEnv: Record<string, string> = {};
    for (const [key, value] of Object.entries(env)) {
      if (value !== undefined) expansionEnv[key] = value;
    }
    const expanded = expand({ parsed, processEnv: expansionEnv }).parsed;
    if (expanded) populate(env, expanded);
  }
}
