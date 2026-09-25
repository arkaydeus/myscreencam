#!/usr/bin/env node
// Baseline: time the OLD Electron app's export (Rust daemon + FFmpeg) on a copy of a recording package,
// while scripts/perf/sample.py measures the daemon's process tree (daemon + ffmpeg child).
//
// usage: node scripts/perf/legacy-export-baseline.mjs <package-dir> [quality=high] [fps=30]
// env:   LEGACY_REPO (default /Users/arkaydeus/project/apps/myscreenart) — daemon must be built (cargo build --release)

import { spawn } from 'node:child_process';
import { cpSync, mkdtempSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

const [packageDir, quality = 'high', fps = '30'] = process.argv.slice(2);
if (!packageDir) {
  console.error('usage: legacy-export-baseline.mjs <package-dir> [quality] [fps]');
  process.exit(2);
}

const legacyRepo = process.env.LEGACY_REPO ?? '/Users/arkaydeus/project/apps/myscreenart';
const daemonPath = join(legacyRepo, 'target/release/screen-recorder-daemon');
const sampler = join(dirname(fileURLToPath(import.meta.url)), 'sample.py');

// Work on a copy so the original recording is never touched.
const root = mkdtempSync(join(tmpdir(), 'msa-legacy-baseline-'));
const pkg = join(root, basename(packageDir));
cpSync(packageDir, pkg, { recursive: true });
const output = join(root, `export-${quality}-${fps}.mp4`);

const daemon = spawn(daemonPath, [], {
  env: {
    ...process.env,
    MYSCREENART_RECORDINGS_DIR: root,
    MYSCREENART_RESOURCES_DIR: join(legacyRepo, 'apps/desktop/resources'),
  },
  stdio: ['ignore', 'pipe', 'inherit'],
});

const { port, token } = await new Promise((resolve, reject) => {
  const lines = createInterface({ input: daemon.stdout });
  lines.once('line', (line) => resolve(JSON.parse(line)));
  daemon.once('exit', (code) => reject(new Error(`daemon exited early (${code})`)));
});

const samplerProc = spawn('python3', [sampler, '--pid', String(daemon.pid), '--interval', '0.25', '--label', `legacy export ${quality}@${fps}fps`], {
  stdio: ['ignore', 'inherit', 'inherit'],
});

const ws = new WebSocket(`ws://127.0.0.1:${port}`);
const pending = new Map();
const call = (method, params = {}) =>
  new Promise((resolve, reject) => {
    const id = crypto.randomUUID(); // the daemon requires UUID request ids
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
  });

const done = new Promise((resolve, reject) => {
  ws.onmessage = ({ data }) => {
    const msg = JSON.parse(data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve: ok, reject: fail } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? fail(new Error(msg.error.message)) : ok(msg.result);
    } else if (msg.method === 'export_done') resolve(msg.params);
    else if (msg.method === 'export_error') reject(new Error(msg.params.message));
  };
});

await new Promise((resolve) => (ws.onopen = resolve));
await call('auth', { token });

const started = performance.now();
await call('export_start', { package_path: pkg, output_path: output, quality, frame_rate: Number(fps) });
try {
  await done;
  const seconds = (performance.now() - started) / 1000;
  console.log(`export wall: ${seconds.toFixed(1)} s, output ${(statSync(output).size / 1_048_576).toFixed(1)} MB → ${output}`);
} finally {
  samplerProc.kill('SIGINT');
  await new Promise((resolve) => samplerProc.once('exit', resolve));
  ws.close();
  daemon.kill();
  if (!process.env.KEEP_OUTPUT) rmSync(root, { recursive: true, force: true });
}
