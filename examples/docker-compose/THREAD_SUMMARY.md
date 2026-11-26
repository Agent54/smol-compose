# Agent handoff: Docker Compose embedding

This guide covers integrating the Compose backend into a macOS Apple Silicon
Swift application.

## Ready-to-use integration release

Select the [latest release](https://github.com/Agent54/smol-compose/releases/latest)
and record its tag in the application's build configuration. Download the
matching assets from that release during the app build:

- `smolvm-<version>-darwin-arm64.tar.gz`
- `smolvm-<version>-docker-compose-darwin-arm64.smolmachine`
- `checksums.sha256`

Verify the artifacts against that release's `checksums.sha256`. For embedded
build support, also obtain the matching `.smolmachine.builder.lock` and check
its metadata against the consuming application's requirements. See the
[release asset guidance](README.md#release-asset-boundary).

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
Compose through `machine exec -- docker compose ...`. The packaged Docker VM
contains Docker Compose. Add host ports and socket bridges only when the app has
a concrete need for them.

## Asset boundary

The normal runtime archive supplies:

- the signed/ad-hoc-signed `smolvm-bin` host executable and wrapper;
- the matching static ARM64 Linux agent rootfs;
- storage and overlay templates;
- the pinned NET-enabled libkrun runtime and its dependencies.

Preserve the extracted layout. `lib/libkrun.2.dylib` is a required symlink to
`libkrun.dylib`; selecting only unversioned dylibs will break process startup.

The Compose sidecar supplies the Docker DinD image layers selected by
[`docker-compose.smolfile`](docker-compose.smolfile) and
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
- machine creation from the sidecar without pulling its base Docker image.

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

The fork is [Agent54/smol-compose](https://github.com/Agent54/smol-compose),
on the `compose` branch. Consult the selected release's notes and
[GitHub Actions](https://github.com/Agent54/smol-compose/actions) for its build
and Compose verification results. [`VALIDATION.md`](VALIDATION.md) records a
historical integration run. The maintained verification procedure is in
[`README.md`](README.md#one-command-verification).
