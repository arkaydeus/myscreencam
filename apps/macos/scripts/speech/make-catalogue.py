#!/usr/bin/env python3
"""Builds the speech-model catalogue (pinned revisions, file inventory, sizes, SHA-256) from Hugging Face.

    scripts/speech/make-catalogue.py > Packages/MyScreenArtKit/Sources/SpeechCore/Resources/catalogue.json
    scripts/speech/make-catalogue.py --download DIR   # also fetch every file into DIR/<id>/ and verify it

LFS files carry their SHA-256 in the tree listing; small git files are downloaded and hashed. Revisions are pinned
in REPOS below; bump them deliberately and review the licence files of the new revision.
"""

import hashlib
import json
import os
import sys
import urllib.request

REPOS = [
    {
        "id": "parakeet-ultra-coreml",
        "repository": "FluidInference/parakeet-ultra-coreml",
        "revision": "95eaa59a39d4394f047a4dc5cce480388a60d1b6",
        "format": "coreml",
        "quantisation": "int8-encoder",
        "license": "CC-BY-4.0",
        "attribution": "Parakeet Ultra by Moondream (moondream/parakeet-ultra), post-trained from NVIDIA "
        "parakeet-tdt-0.6b-v3; Core ML conversion by FluidInference.",
    },
    {
        "id": "qwen3-asr-1.7b-8bit",
        "repository": "mlx-community/Qwen3-ASR-1.7B-8bit",
        "revision": "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
        "format": "mlx-safetensors",
        "quantisation": "8bit",
        "license": "Apache-2.0",
        "attribution": "Qwen3-ASR-1.7B by the Qwen team, Alibaba Cloud; MLX 8-bit conversion by mlx-community.",
    },
    {
        "id": "qwen3-aligner-0.6b-8bit",
        "repository": "mlx-community/Qwen3-ForcedAligner-0.6B-8bit",
        "revision": "0e1a68e91d815300c7c9754b2a7639378b23db15",
        "format": "mlx-safetensors",
        "quantisation": "8bit",
        "license": "Apache-2.0",
        "attribution": "Qwen3-ForcedAligner-0.6B by the Qwen team, Alibaba Cloud; MLX 8-bit conversion by "
        "mlx-community.",
    },
]

# Files the runtime never reads (repository housekeeping, benchmark artefacts).
SKIP = {".gitattributes"}


def get(url):
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()


def resolve_url(repo, revision, path):
    return f"https://huggingface.co/{repo}/resolve/{revision}/{path}"


def main():
    download_dir = None
    if len(sys.argv) == 3 and sys.argv[1] == "--download":
        download_dir = sys.argv[2]
    models = []
    for spec in REPOS:
        tree = json.loads(get(f"https://huggingface.co/api/models/{spec['repository']}/tree/{spec['revision']}?recursive=true"))
        files = []
        for entry in sorted((e for e in tree if e["type"] == "file"), key=lambda e: e["path"]):
            path = entry["path"]
            if path in SKIP:
                continue
            url = resolve_url(spec["repository"], spec["revision"], path)
            lfs = entry.get("lfs")
            if lfs:
                sha, size = lfs["oid"], lfs["size"]
            else:
                data = get(url)
                sha, size = hashlib.sha256(data).hexdigest(), len(data)
            files.append({"path": path, "size": size, "sha256": sha})
            if download_dir:
                dest = os.path.join(download_dir, spec["id"], path)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                if not (os.path.exists(dest) and os.path.getsize(dest) == size):
                    print(f"downloading {spec['id']}/{path} ({size} bytes)", file=sys.stderr)
                    urllib.request.urlretrieve(url, dest)
                h = hashlib.sha256()
                with open(dest, "rb") as f:
                    for block in iter(lambda: f.read(1 << 20), b""):
                        h.update(block)
                if h.hexdigest() != sha:
                    sys.exit(f"hash mismatch: {dest}")
        model = dict(spec)
        model["files"] = files
        models.append(model)
    json.dump({"schemaVersion": 1, "models": models}, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
