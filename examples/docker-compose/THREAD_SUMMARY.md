# Agent handoff: Docker Compose embedding

This is the current handoff for an agent integrating the Compose backend into
a macOS Apple Silicon Swift application. Historical feasibility details were
removed because they described SmolVM 1.7.5 and predated the maintained,
release-tested implementation.

## Ready-to-use integration release

Use the complete immutable prerelease:

[`compose-integration-1.13.0-1706c07.1`](https://github.com/Agent54/smol-compose/releases/tag/compose-integration-1.13.0-1706c07.1)

Download all three assets from that release:

- `smolvm-1.13.0-darwin-arm64.tar.gz`
- `smolvm-1.13.0-docker-compose-darwin-arm64.smolmachine`
- `checksums.sha256`

The runtime archive SHA-256 is
`93dccc758df880a707f53fcb62ca393fea7538f07361280fb0dcc4c12323b714`.
The Compose sidecar SHA-256 is
`acaa84066ca78f07d47a7e1358e12e90ac6f5b54b6c3344b5bd98d343e26b9bc`.
The older tag without the `.1` suffix contains only the sidecar and is not a
complete Swift embedding input.

## Minimal Swift architecture

Use the process boundary documented in [`SWIFT_EMBEDDING.md`](SWIFT_EMBEDDING.md):

```text
Swift actor or XPC service
  -> Foundation.Process
  -> bundled smolvm-bin
  -> bundled Docker Compose .smolmachine
  -> dockerd and docker compose inside the Linux VM
```

There is no required Swift package, Docker SDK, Docker Desktop, host Docker
daemon, Homebrew dependency, Rust toolchain, or runtime image build. Invoke
`smolvm-bin` directly with an argument array and the bundled runtime paths in
its environment. Do not use a shell command string.

For the first integration, create the machine from the sidecar with only
`--net-backend virtio-net` and the app-owned project-directory volume. Control
Compose through `machine exec -- docker compose ...`. The sidecar contains
Docker Compose v2.40.3. Add host ports and socket bridges only when the app has
a concrete need for them.

## Asset boundary

The normal runtime archive supplies:

- the signed/ad-hoc-signed `smolvm-bin` host executable and wrapper;
- the static ARM64 Linux 1.13.0 agent rootfs;
- storage and overlay templates;
- the pinned NET-enabled libkrun runtime and its dependencies.

Preserve the extracted layout. `lib/libkrun.2.dylib` is a required symlink to
`libkrun.dylib`; selecting only unversioned dylibs will break process startup.

The Compose sidecar supplies the official `docker:28-dind` image layers and
workload configuration. It is not a custom OCI image asset. The DinD
entrypoint starts dockerd automatically on every VM start, using
`/storage/docker` on the persistent ext4 disk.

## Runtime capabilities

The maintained implementation supports:

- host TCP forwarding through the VM to Compose containers;
- `/var/run/docker.sock` exposed from the guest to an optional host client;
- arbitrary host-to-guest Unix sockets with `--mount-socket HOST:GUEST`;
- arbitrary guest-to-host Unix sockets with `--expose-socket GUEST:HOST`;
- persistent Docker images, containers, volumes, and project state;
- automatic dockerd restart with the VM; and
- machine creation from the sidecar without pulling `docker:28-dind`.

Compose bind-source paths are resolved by the daemon inside the VM. Mount the
app-owned macOS project directory into the VM, then use guest paths such as
`/workspace/projects/web-stack/data` in Compose files.

## Safety constraints

- Keep `SMOLVM_DATA_DIR` short because macOS Unix socket paths are limited to
  roughly 104 bytes.
- Put app sockets below a private mode-`0700` directory.
- Delete only enumerated app-owned socket suffixes and exact machine names.
- Treat access to the Docker socket as control of the VM and its host mounts.
- Serialize machine lifecycle changes in a Swift actor or XPC service.
- Drain child stdout and stderr concurrently.
- Keep destructive operations such as `machine delete` and Compose
  `down --volumes` behind explicit user actions.

## Repository and CI state

The fork is `Agent54/smol-compose`. The `compose` branch is based on current
upstream SmolVM 1.13.0 and points at `1706c07`; runtime changes are in
`c3a9fcc`, while `1706c07` changes only Compose CI bootstrap.

Local build, unit-test, Clippy, libkrun provenance, socket, restart, pack, and
embedded-artifact checks passed. The GitHub-hosted CI for the rebased runtime
passed. The self-hosted Compose job is currently an infrastructure issue: its
runner cannot install or locate Homebrew/Git LFS during checkout. The complete
integration prerelease was therefore built and validated manually. Swift app
integration should consume the immutable release and does not need to wait for
that runner repair.
