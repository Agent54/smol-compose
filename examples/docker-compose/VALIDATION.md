# Validation record

This is a historical validation record for the release identified below.
For current downloads, use the
[latest release](https://github.com/Agent54/smol-compose/releases/latest).
Consult its release notes and workflow results for validation of those artifacts.

## Historical rebased release validation

The maintained example was validated on Apple Silicon macOS after rebasing the
Compose work onto SmolVM 1.13.0. Runtime code is commit `c3a9fcc`; the release
tag targets `1706c07`, whose only additional change is CI bootstrap.

The complete immutable integration prerelease is:

[`compose-integration-1.13.0-1706c07.1`](https://github.com/Agent54/smol-compose/releases/tag/compose-integration-1.13.0-1706c07.1)

It contains:

```text
93dccc758df880a707f53fcb62ca393fea7538f07361280fb0dcc4c12323b714  smolvm-1.13.0-darwin-arm64.tar.gz
acaa84066ca78f07d47a7e1358e12e90ac6f5b54b6c3344b5bd98d343e26b9bc  smolvm-1.13.0-docker-compose-darwin-arm64.smolmachine
```

The Darwin runtime archive was built in the example's ignored `state`
directory from the exact CI-built static ARM64 agent/rootfs and the repository's
bundled libkrun. Validation confirmed:

- the wrapper starts and reports `smolvm 1.13.0`;
- the `smolvm-bin` macOS signature verifies;
- the guest agent is a statically linked ARM64 Linux executable;
- `libkrun.2.dylib -> libkrun.dylib` is present;
- libkrun's Homebrew build paths were relocated to bundled dylibs; and
- storage and overlay templates are packaged, so the consuming Swift app does
  not need `mkfs.ext4` or Homebrew.

## End-to-end behavior

The full five-stage verifier passed on the rebased runtime and produced the
published 133 MiB sidecar:

1. A normal Smolfile-created machine started the official `docker:28-dind`
   workload and dockerd automatically.
2. Host TCP forwarding and both arbitrary Unix-socket directions passed.
3. The VM was stopped and restarted; Docker and the Compose workload recovered
   from persistent storage and all probes passed again.
4. `pack create` embedded the Docker image and workload configuration.
5. A fresh machine created from that `.smolmachine` started without pulling
   `docker:28-dind` and passed the same TCP and socket probes.

A subsequent manual run using the exact CI-built rootfs independently repeated
the normal-machine and restart phases successfully. That run was interrupted
during a redundant pack rebuild; the release sidecar remains the output of the
earlier complete five-stage pass. A separate machine created with the exact
released runtime archive and published sidecar reported `Docker Compose version
v2.40.3` and `overlay2 28.5.2` from `docker info`. This proves the complete
three-file release pairing and the dependency-free `machine exec -- docker
compose ...` control path used by the Swift guide.

All validation databases, disks, downloaded CI artifacts, build staging,
release artifacts, logs, and sockets were confined to the ignored
`examples/docker-compose/state/` directory. No validation machines remain.

## Source and libkrun checks

The fork pins libkrun as a submodule and builds it with `BLK=1 NET=1 GPU=1`.
The musl target is required so the embedded krun-init is a static Linux ARM64
executable. The bundled macOS libkrun was checked for the required feature set
and host symbols, including `krun_add_net_unixstream` for virtio-net and socket
bridges. Provenance checks passed for all bundled platforms.

Repository verification also passed:

- `cargo test -p smolvm-agent`: 170 tests;
- root-library tests: 662 tests;
- `cargo clippy --all-targets -- -D warnings`;
- bundled libkrun provenance and exported-symbol checks; and
- LFS integrity for the complete rebased range before its guarded push.

The normal GitHub CI run for runtime commit `c3a9fcc` completed successfully.
The self-hosted Compose workflow currently fails for runner provisioning before
checkout because Git LFS/Homebrew is unavailable in that runner environment;
this is separate from the manually validated runtime and release artifacts.

## Behavioral details that remain important

There are two port-publishing layers:

```text
container port -> VM port -> macOS host port
```

Compose declares the first. SmolVM's `--port HOST:GUEST` declares the second.

Docker bind sources are resolved inside the VM because dockerd runs there.
Compose files must use guest paths below an explicitly mounted host project
directory. Ordinary virtiofs mounts do not proxy Unix-socket semantics; use
`--mount-socket` and `--expose-socket` for sockets.

Docker state is stored directly at `/storage/docker` on the persistent ext4
disk with `overlay2`. This avoids nesting Docker's writable overlay beneath the
container rootfs overlay and allows state to survive VM restarts.
