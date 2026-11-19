#!/usr/bin/env python3
"""Verify the bundled image config and every layer against the pinned image ID."""
import gzip
import hashlib
import json
import sys
import tarfile

with tarfile.open(sys.argv[1]) as archive:
    manifests = json.load(archive.extractfile("manifest.json"))
    if len(manifests) != 1:
        raise ValueError("Expected one ARM64 BuildKit image")
    manifest = manifests[0]
    config_bytes = archive.extractfile(manifest["Config"]).read()
    if "sha256:" + hashlib.sha256(config_bytes).hexdigest() != sys.argv[2]:
        raise ValueError("BuildKit image identity does not match the lock")
    config = json.loads(config_bytes)
    if config["architecture"] != "arm64" or config["os"] != "linux":
        raise ValueError("Expected Linux ARM64 BuildKit")
    identities = config["rootfs"]["diff_ids"]
    if len(identities) != len(manifest["Layers"]):
        raise ValueError("BuildKit layer count does not match its configuration")
    for name, identity in zip(manifest["Layers"], identities):
        with gzip.GzipFile(fileobj=archive.extractfile(name)) as layer:
            digest = hashlib.sha256()
            for chunk in iter(lambda: layer.read(1024 * 1024), b""):
                digest.update(chunk)
        if "sha256:" + digest.hexdigest() != identity:
            raise ValueError(f"BuildKit layer checksum mismatch: {name}")
print("Verified BuildKit image identity and all layer contents")
