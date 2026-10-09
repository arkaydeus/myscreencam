import { fileURLToPath } from "node:url";

import type { NextConfig } from "next";

import { loadRootEnv } from "./scripts/root-env";

// Next.js loads apps/web first. Add the repo-root defaults without using its cached @next/env loader.
loadRootEnv(fileURLToPath(new URL("../..", import.meta.url)));

const nextConfig: NextConfig = {/* config options here */};

export default nextConfig;
