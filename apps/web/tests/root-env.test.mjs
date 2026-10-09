import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { loadRootEnv } from "../scripts/root-env";

test.each(["development", "production", "test"])(
  "root defaults load after Next.js loads the app in %s, preserving host and app precedence",
  (mode) => {
    const temporary = mkdtempSync(join(tmpdir(), "myscreencam-env-"));
    const root = join(temporary, "repo");
    const app = join(root, "apps/web");
    mkdirSync(app, { recursive: true });
    try {
      writeFileSync(join(app, ".env"), "ENV_APP_SENTINEL=app\nENV_HOST_SENTINEL=app\n");
      writeFileSync(
        join(root, ".env"),
        [
          "ENV_ROOT_SENTINEL=root",
          "ENV_APP_SENTINEL=root",
          "ENV_HOST_SENTINEL=root",
          "ENV_EMPTY_SENTINEL=root",
          "ENV_MODE_SENTINEL=base",
          "ENV_LOCAL_SENTINEL=base",
          "ENV_EXPANDED_SENTINEL=$ENV_APP_SENTINEL/$ENV_HOST_SENTINEL/$ENV_ROOT_SENTINEL",
          String.raw`ENV_LITERAL_SENTINEL=escaped\$value`,
        ].join("\n"),
      );
      writeFileSync(
        join(root, `.env.${mode}`),
        "ENV_MODE_SENTINEL=mode\nENV_LOCAL_SENTINEL=mode\n",
      );
      writeFileSync(join(root, ".env.local"), "ENV_LOCAL_SENTINEL=local\n");
      writeFileSync(join(root, `.env.${mode}.local`), "ENV_MODE_SENTINEL=mode-local\n");
      // A subprocess keeps @next/env's cached initial environment out of the other test files.
      // Its cwd has no .env files, so Bun's own automatic env loading cannot pre-load the fixtures.
      const child = spawnSync(
        process.execPath,
        [
          "--eval",
          `
        import { loadEnvConfig } from ${JSON.stringify(import.meta.resolve("@next/env"))};
        import { loadRootEnv } from ${JSON.stringify(import.meta.resolve("../scripts/root-env.ts"))};
        const root = ${JSON.stringify(root)};
        loadEnvConfig(${JSON.stringify(app)}, ${mode === "development"});
        if (process.env.ENV_APP_SENTINEL !== "app" || process.env.ENV_ROOT_SENTINEL !== undefined) {
          throw new Error("App must load before root");
        }
        loadRootEnv(root);
        console.log(JSON.stringify(Object.fromEntries(
          Object.entries(process.env).filter(([key]) => key.startsWith("ENV_"))
        )));
      `,
        ],
        {
          cwd: temporary,
          env: { NODE_ENV: mode, ENV_HOST_SENTINEL: "host", ENV_EMPTY_SENTINEL: "" },
          encoding: "utf8",
        },
      );
      expect(child.error).toBeUndefined();
      expect(child.stderr).toBe("");
      expect(child.status).toBe(0);
      expect(JSON.parse(child.stdout)).toEqual({
        ENV_HOST_SENTINEL: "host",
        ENV_EMPTY_SENTINEL: "",
        ENV_APP_SENTINEL: "app",
        ENV_ROOT_SENTINEL: "root",
        ENV_MODE_SENTINEL: "mode-local",
        ENV_LOCAL_SENTINEL: mode === "test" ? "mode" : "local",
        ENV_EXPANDED_SENTINEL: "app/host/root",
        ENV_LITERAL_SENTINEL: "escaped$value",
      });
    } finally {
      rmSync(temporary, { recursive: true, force: true });
    }
  },
);

test("a root without env files is allowed", () => {
  const root = mkdtempSync(join(tmpdir(), "myscreencam-env-"));
  const env = { NODE_ENV: "production", EXISTING: "value" };
  try {
    loadRootEnv(root, env);
    expect(env).toEqual({ NODE_ENV: "production", EXISTING: "value" });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
