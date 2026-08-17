# Docker Compose backend

This example runs the official Docker-in-Docker image as a persistent SmolVM
workload and drives it from host `docker-compose` through SmolVM's
guest-to-host Docker socket bridge. The image entrypoint starts `dockerd`
automatically whenever the VM starts.

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

The script creates unique test machines and keeps every generated database,
disk, log, staging file, artifact, and socket below the ignored
`examples/docker-compose/.state/` directory. It stops and deletes only the
unique machines it created after a successful run. Set `KEEP_STATE=1` to keep
the machines and packed artifact for inspection. Set `SMOLVM=/path/to/smolvm`
to test a distribution binary instead of `target/release/smolvm`.

Set `EXPORT_PACK=1` to retain the verified sidecar at the fixed,
platform-qualified path
`examples/docker-compose/.state/docker-compose-runtime-<os>-<arch>.smolmachine`.
The script still removes its unique test machines, sockets, launcher, staging
directory, and logs. Tagged-release CI uses this mode to publish the exact
sidecar that passed the embedded-artifact test.

## Requirements

- a current SmolVM build whose libkrun includes block and virtio-net support;
- `docker` and `docker-compose` host clients;
- `socat`, `curl`, and Python 3 on the host.

The host does not need a Docker daemon. Both Docker Engine and the containers
run inside the VM.

For the underlying kernel, storage-driver, and Docker-socket rationale, see
[`../docker-in-vm/docker.smolfile`](../docker-in-vm/docker.smolfile).

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

In terminal 2:

```sh
smolvm machine create \
  --name docker-compose-evaluation \
  --smolfile examples/docker-compose/docker-compose.smolfile \
  --net-backend virtio-net \
  --port 18080:8080 \
  --expose-socket "/var/run/docker.sock:$PWD/examples/docker-compose/.state/docker.sock" \
  --mount-socket "$PWD/examples/docker-compose/.state/host-to-vm.sock:/run/smol-compose-evaluation/host.sock" \
  --expose-socket "/run/smol-compose-evaluation/guest.sock:$PWD/examples/docker-compose/.state/vm-to-host.sock"
```

```sh
smolvm machine start --name docker-compose-evaluation
```

The first start pulls `docker:28-dind`; subsequent starts use the persistent
image layers. The image entrypoint starts `dockerd` with its data root on the
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
python3 examples/docker-compose/fixtures/socket_probe.py \
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

Bundle the Docker image, image metadata, VM runtime, agent rootfs, and disk
template into a portable release artifact:

```sh
smolvm pack create \
  --smolfile examples/docker-compose/docker-compose.smolfile \
  --output examples/docker-compose/.state/docker-compose-runtime
```

The result includes
`examples/docker-compose/.state/docker-compose-runtime.smolmachine`. An
embedded distribution can ship that sidecar and create a ready-to-start
machine without pulling the Docker image:

```sh
smolvm machine create \
  --name docker-compose-evaluation \
  --from examples/docker-compose/.state/docker-compose-runtime.smolmachine \
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
publish or require a custom Docker OCI image: the official `docker:28-dind`
image and its startup metadata are already embedded in the sidecar.

An embedding application needs both release assets:

- the normal platform distribution, which contains the signed `smolvm` host
  executable, bundled `libkrun`/`libkrunfw`, agent rootfs, and disk templates;
- the matching Docker Compose `.smolmachine`, which contains the Docker guest
  image layers and workload configuration.

For a macOS Apple Silicon Swift app, download the tagged `darwin-arm64`
distribution and `smolvm-<version>-docker-compose-darwin-arm64.smolmachine`,
verify both against `checksums.sha256`, and copy them into the app bundle. No
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
