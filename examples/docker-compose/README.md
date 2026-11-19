# Docker Compose backend

This example runs the official Docker-in-Docker image as a persistent SmolVM
workload and drives it from host `docker-compose` through SmolVM's
guest-to-host Docker socket bridge. The image entrypoint starts `dockerd`
automatically whenever the VM starts.

The ARM64 runtime is assembled by `prepare-runtime.sh` from the digest-pinned
Docker 29.9.3 DinD image. Before packing, it installs Buildx 0.39.0 and the
digest-pinned BuildKit 0.35.0 archive in the guest filesystem. No guest engine
executables need to be supplied or mounted by a consuming Mac app.

The guest `/usr/local/share/xe-builder/prepare-builder.sh` is called only when
a build is requested. It imports the image and creates the builder container
with Docker's `--pull=never`, then lets Buildx start it under the same lock.
Buildx would otherwise attempt a registry pull even for a loaded image ID.
A missing bundled image fails instead of downloading a replacement. Its restart
policy is `no`, so restarting Docker or the VM does not restart BuildKit.
`cache.sh` performs maintenance only while the builder is already running.
Neither script is part of the VM startup entrypoint.

The packed artifact is accompanied by `.smolmachine.builder.lock`, recording
its checksum and embedded versions.

Docker uses the containerd image store (`containerd-snapshotter=true`). This
DinD distribution starts Docker-managed containerd, which keeps its contents
and overlayfs snapshots under `/storage/docker/containerd/daemon`. That path
is on the VM's persistent ext4 disk, outside its layered root filesystem.
There is no separate containerd service or extra startup mount.

For a dependency-free macOS application integration that embeds the released
runtime and runs Compose inside the VM, see
[`SWIFT_EMBEDDING.md`](SWIFT_EMBEDDING.md).

The previous Apple Silicon integration prerelease is
[`compose-integration-1.13.0-1706c07.1`](https://github.com/Agent54/smol-compose/releases/tag/compose-integration-1.13.0-1706c07.1).
It predates the embedded BuildKit image and cannot be used by consumers that
require `containerd-buildkit-2` metadata. Build this revision through the
verification pipeline below until a matching component release is published.

It validates all of the paths needed by a local Compose backend:

- a host TCP port forwarded through the VM to a Compose container;
- the guest Docker socket exposed to a host Docker client;
- a host Unix socket mounted into the VM and Compose container; and
- a Compose-container Unix socket exposed through the VM to the host.

Run the commands below from the smolvm repository root.

## One-command verification

With a release build and its agent rootfs available, run the complete normal,
restart, pack, and embedded-artifact test:

```sh
./examples/docker-compose/verify.sh
```

The check also uploads files of 1 MiB, 1 MiB plus one byte, and multiple chunks
to `/tmp`, `/workspace`, and `/opt` while another overlay is prepared. It checks
the destination from the running workload, along with file contents,
permissions, ownership, and download results.

The script creates unique test machines and keeps every generated database,
disk, log, staging file, artifact, and socket below the ignored
`examples/docker-compose/.state/` directory. It stops and deletes only the
unique machines it created after a successful run. Set `KEEP_STATE=1` to keep
the machines and packed artifact for inspection. Set `SMOLVM=/path/to/smolvm`
to test a distribution binary instead of `target/release/smolvm`.

For a local rebuild, set `SMOLVM_BUILD_BASE_ARTIFACT` to a previous pristine
artifact produced by this image recipe, with its `.builder.lock` alongside it.
The build verifies its checksum, Docker version and exact Docker image reference, reuses its base layers,
and reapplies the current recipe before packing. This avoids downloading Docker
again. It is a build input, not a migration path for a running user's VM.

`SMOLVM_VERIFY_IMAGE_ARCHIVE` can supply a locally saved Docker archive containing
the Compose fixture images. Verification loads it into each test VM and disables
pulling, so repeated tests do not redownload the Python fixture.

The builder lock pins the BuildKit registry reference. Archives are cached by
that digest and validated by Crane. On the first build, Docker loads the archive
and supplies the image ID used by Buildx. The guest saves that ID under the pinned
digest and asks Docker whether it still exists before reuse. If it was pruned,
Docker reloads the bundled archive. Mutable image tags are never used to select
the builder. No host code calculates Docker's internal image identity.

On macOS CI checkouts whose absolute path would exceed the Unix-socket limit,
the script temporarily addresses that same `.state` directory through a short,
PID-scoped symlink in `/tmp`. The symlink is removed on exit; all state and
socket filesystem objects remain physically inside the ignored `.state`
directory.

Set `EXPORT_PACK=1` to retain the verified sidecar at the fixed,
platform-qualified path
`examples/docker-compose/.state/docker-compose-runtime-<os>-<arch>.smolmachine`.
The script still removes its unique test machines, sockets, launcher, staging
directory, and logs. Tagged-release CI uses this mode to publish the exact
sidecar that passed the embedded-artifact test.

## Requirements

- a current SmolVM build whose libkrun includes block and virtio-net support;
- `docker` and `docker-compose` host clients;
- `socat`, `curl`, Crane, and Python 3 on the host.

The host does not need a Docker daemon. Both Docker Engine and the containers
run inside the VM.

For the underlying kernel, storage-driver, and Docker-socket rationale, see
[`../docker-in-vm/docker.smolfile`](../docker-in-vm/docker.smolfile).

### Self-hosted macOS runner setup

The Compose integration and release jobs on `[self-hosted, macOS, ARM64, raw]`
expect tools to be installed by the machine administrator. They check for
dependencies and fail with setup instructions; they do not invoke Homebrew.
The integration job checks Git LFS before checkout so a missing executable does
not fail inside `actions/checkout`.

The runner service uses the PATH saved in `actions-runner/.path` by
[`env.sh`](https://github.com/actions/runner/blob/main/src/Misc/layoutroot/env.sh).
[`runsvc.sh`](https://github.com/actions/runner/blob/main/src/Misc/layoutbin/runsvc.sh)
loads that file when started by `./svc.sh start`. Adding a directory to
`.zshrc` or installing a tool in an interactive shell does not update the
service's saved PATH.

Download the Mac Apple Silicon archive from [Git LFS](https://git-lfs.com/)
and extract it. As the same user that runs the macOS runner service, install
the extracted `git-lfs` binary in a dedicated directory and update the saved
service PATH. Run this from the runner installation directory, not the
repository checkout:

```sh
cd /path/to/actions-runner
./svc.sh stop
mkdir -p tools/bin
install -m 0755 /path/to/extracted/git-lfs tools/bin/git-lfs
printf '%s\n' "$PWD/tools/bin:$(cat .path)" > .path
env PATH="$(cat .path)" /bin/bash --noprofile --norc -c 'git lfs version'
./svc.sh start
```

This preserves existing PATH entries and exposes Git LFS without adding the
Homebrew `bin` directory. Keep any Homebrew `bin` entries out of `.path` if the
service must not be able to invoke `brew`. Do not run macOS `svc.sh` with sudo.

Provision `docker`, `docker-compose` (or the Docker Compose plugin), `socat`,
`curl`, `crane`, and Deno the same way: their executable directories must be in
`.path`, and the service must be restarted after changes. The integration job
also needs e2fsprogs for `mkfs.ext4`; SmolVM searches the standard installation
paths, or you can expose its `sbin` directory through `.path`. The release job
uses the distribution's bundled disk templates. No host Docker daemon is
needed.

## 1. Start the host Unix-socket fixture

Create the example's ignored runtime directory:

```sh
mkdir -p examples/docker-compose/.state
```

Keep the test machine database, disks, logs, and runtime sockets there too:

```sh
export SMOLVM_DATA_DIR="$PWD/examples/docker-compose/.state"
```

Use the same exported value for every `smolvm` command in this example.

In terminal 1, start a host socket that returns `host-to-vm-ok`:

```sh
socat UNIX-LISTEN:"$PWD/examples/docker-compose/.state/host-to-vm.sock",fork SYSTEM:"printf 'host-to-vm-ok\\n'"
```

Leave that process running.

## 2. Create and start the machine

In terminal 2, build and verify the artifact first:

```sh
EXPORT_PACK=1 ./examples/docker-compose/verify.sh
```

Then create the machine from that artifact (Apple Silicon path shown):

```sh
smolvm machine create \
  --name docker-compose-evaluation \
  --from examples/docker-compose/.state/docker-compose-runtime-darwin-arm64.smolmachine \
  --net-backend virtio-net \
  --port 18080:8080 \
  --expose-socket "/var/run/docker.sock:$PWD/examples/docker-compose/.state/docker.sock" \
  --mount-socket "$PWD/examples/docker-compose/.state/host-to-vm.sock:/run/smol-compose-evaluation/host.sock" \
  --expose-socket "/run/smol-compose-evaluation/guest.sock:$PWD/examples/docker-compose/.state/vm-to-host.sock"
```

```sh
smolvm machine start --name docker-compose-evaluation
```

The packed image already contains Docker and the build tools. The image
entrypoint starts `dockerd` with its data root on the
VM's persistent ext4 storage disk. The Smolfile passes an explicit Unix-only
Docker host, so the DinD entrypoint does not add its unauthenticated TCP
listener.

## 3. Wait for Docker Engine

The image workload starts Docker automatically. Check readiness:

```sh
smolvm machine exec --name docker-compose-evaluation -- docker info
```

If Docker is still starting, run the readiness command again. Docker data is
written directly to `/storage/docker` on the persistent ext4 disk, avoiding
nested overlayfs.

## 4. Connect host Compose to the guest daemon

Set `DOCKER_HOST` to the socket exposed in the example's ignored state
directory:

```sh
export DOCKER_HOST="unix://$PWD/examples/docker-compose/.state/docker.sock"
```

Confirm that the client reaches the daemon inside the VM:

```sh
docker info
```

Start the Compose application:

```sh
docker-compose -f examples/docker-compose/compose.yaml up -d --wait
```

The `/run/smol-compose-evaluation` bind source in `compose.yaml` is a guest
path. Bind paths are resolved by the Docker daemon, which runs inside the VM,
rather than by the host client.

## 5. Validate the backend paths

Host TCP port `18080` through the VM and Compose container:

```sh
curl --fail http://127.0.0.1:18080
```

Expected output:

```text
port-exposure-ok
```

Compose container through the mounted VM socket to the host fixture:

```sh
docker-compose -f examples/docker-compose/compose.yaml exec -T app \
  python -c 'import socket; s=socket.socket(socket.AF_UNIX); s.connect("/run/smol-compose-evaluation/host.sock"); s.sendall(b"probe\n"); s.shutdown(socket.SHUT_WR); print(s.recv(4096).decode().strip())'
```

Expected output:

```text
host-to-vm-ok
```

Host through the exposed VM socket to the Compose container:

```sh
deno run --no-config --allow-read --allow-write --allow-net examples/docker-compose/fixtures/socket_probe.ts \
  examples/docker-compose/.state/vm-to-host.sock vm-to-host-ok
```

Expected output:

```text
vm-to-host-ok
```

## Restart behavior

Docker images, containers, and volumes persist under `/storage/docker` across a
machine stop and start. SmolVM relaunches the image workload on each machine
start, so the image entrypoint automatically starts `dockerd`. The Compose
service uses `restart: unless-stopped`, allowing Docker to restore it after the
daemon is ready.

## Build an embedded release artifact

The repository verification pipeline assembles the guest builder, packs the
runtime, tests restart and socket behavior, and exports the verified artifact:

```sh
EXPORT_PACK=1 ./examples/docker-compose/verify.sh
```

The result includes
`examples/docker-compose/.state/docker-compose-runtime-darwin-arm64.smolmachine`
and its `.builder.lock` metadata. An
embedded distribution can ship that sidecar and create a ready-to-start
machine without pulling the Docker image:

```sh
smolvm machine create \
  --name docker-compose-evaluation \
  --from examples/docker-compose/.state/docker-compose-runtime-darwin-arm64.smolmachine \
  --net-backend virtio-net \
  --port 18080:8080 \
  --expose-socket "/var/run/docker.sock:$PWD/examples/docker-compose/.state/docker.sock" \
  --mount-socket "$PWD/examples/docker-compose/.state/host-to-vm.sock:/run/smol-compose-evaluation/host.sock" \
  --expose-socket "/run/smol-compose-evaluation/guest.sock:$PWD/examples/docker-compose/.state/vm-to-host.sock"
```

The Docker socket endpoint, arbitrary socket endpoints, host mounts, and host ports
remain launch-site capabilities: the embedded application chooses their host
paths when it creates the machine rather than baking machine-specific paths
into the portable artifact.

### Release asset boundary

A tagged fork release publishes a platform-qualified Docker Compose
`.smolmachine` alongside the normal SmolVM distribution. It does **not**
publish or require a custom Docker OCI image: the pinned Docker DinD image,
guest Buildx client, BuildKit archive, and startup metadata are embedded in
the sidecar.

An embedding application needs both release assets:

- the normal platform distribution, which contains the signed `smolvm` host
  executable, bundled `libkrun`/`libkrunfw`, agent rootfs, and disk templates;
- the matching Docker Compose `.smolmachine` and `.smolmachine.builder.lock`,
  which contain the guest image, build tools, configuration, and version metadata.

For a macOS Apple Silicon Swift app, download the tagged `darwin-arm64`
distribution and `smolvm-<version>-docker-compose-darwin-arm64.smolmachine`,
verify all assets against `checksums.sha256`, and copy them into the app bundle. No
Docker daemon, Docker.framework, Rust toolchain, or image build dependency is
needed in the Swift app. The app only needs a small wrapper around the bundled
runtime (for example an XPC service or `Process`) and chooses its socket and
port paths when creating the machine.

## Stop without deleting state

```sh
docker-compose -f examples/docker-compose/compose.yaml stop
```

```sh
smolvm machine stop --name docker-compose-evaluation
```

The VM disks, Docker state, and example socket paths remain available for
inspection. Delete them only with explicit `machine delete` and filesystem
commands when they are no longer needed.
