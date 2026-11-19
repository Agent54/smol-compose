#!/usr/bin/env python3
"""Verify image contents and print the manifest identity used by containerd."""
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
    layers = []
    for name, identity in zip(manifest["Layers"], identities):
        with gzip.GzipFile(fileobj=archive.extractfile(name)) as layer:
            digest = hashlib.sha256()
            for chunk in iter(lambda: layer.read(1024 * 1024), b""):
                digest.update(chunk)
        if "sha256:" + digest.hexdigest() != identity:
            raise ValueError(f"BuildKit layer checksum mismatch: {name}")
        compressed_digest = hashlib.sha256()
        with archive.extractfile(name) as compressed:
            for chunk in iter(lambda: compressed.read(1024 * 1024), b""):
                compressed_digest.update(chunk)
        layers.append({
            "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
            "digest": "sha256:" + compressed_digest.hexdigest(),
            "size": archive.getmember(name).size,
        })
    # Docker's containerd importer constructs this schema-2 manifest from a
    # Docker archive. Its identity depends on compressed blobs, not just config.
    # Derive it per artifact so a fresh registry download and a verified local
    # cache both select their exact imported image without hardcoded cache IDs.
    imported = {
        "schemaVersion": 2,
        "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
        "config": {
            "mediaType": "application/vnd.docker.container.image.v1+json",
            "digest": sys.argv[2],
            "size": len(config_bytes),
        },
        "layers": layers,
    }
    encoded = json.dumps(imported, separators=(",", ":")).encode()
    print("sha256:" + hashlib.sha256(encoded).hexdigest())
print("Verified BuildKit config and all layer contents", file=sys.stderr)
