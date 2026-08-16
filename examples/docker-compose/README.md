# Docker Compose backend

This example runs Docker Engine inside a persistent SmolVM machine and drives
it from host `docker-compose` through SmolVM's guest-to-host Docker socket
bridge.

It validates all of the paths needed by a local Compose backend:

- a dedicated host directory mounted into the VM and then into a container;
- a host TCP port forwarded through the VM to a Compose container;
- the guest Docker socket exposed to a host Docker client;
- a host Unix socket mounted into the VM and Compose container; and
- a Compose-container Unix socket exposed through the VM to the host.

Run the commands below from the smolvm repository root. The example has no
cleanup script and does not delete host files automatically.

## Requirements

- a SmolVM build whose libkrun includes block and virtio-net support;
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
  --mount-socket "$PWD/examples/docker-compose/.state/host-to-vm.sock:/run/smol-compose-evaluation/host.sock" \
  --expose-socket "/run/smol-compose-evaluation/guest.sock:$PWD/examples/docker-compose/.state/vm-to-host.sock"
```

```sh
smolvm machine start --name docker-compose-evaluation
```

The Smolfile installs Docker once and mounts the fixture directory at
`/workspace/smol/docker-compose/fixtures` inside the VM.

## 3. Start Docker Engine

Start `dockerd` as a detached guest process:

```sh
smolvm machine exec --name docker-compose-evaluation --detach -- \
  dockerd --data-root=/storage/docker --storage-driver=overlay2
```

Check readiness:

```sh
smolvm machine exec --name docker-compose-evaluation -- docker info
```

If Docker is still starting, run the readiness command again. Docker data is
written directly to the persistent ext4 storage disk. This avoids both nested
overlayfs and the non-persistent `/storage/docker` to `/var/lib/docker` bind
mount used by older examples.

## 4. Connect host Compose to the guest daemon

Print the machine data directory:

```sh
smolvm machine data-dir --name docker-compose-evaluation
```

Set `DOCKER_HOST` to the `docker.sock` inside the printed directory:

```sh
export DOCKER_HOST="unix:///the/printed/machine/data/directory/docker.sock"
```

Confirm that the client reaches the daemon inside the VM:

```sh
docker info
```

Start the Compose application:

```sh
docker-compose -f examples/docker-compose/compose.yaml up -d --wait
```

The absolute bind sources in `compose.yaml` are guest paths. Bind paths are
resolved by the Docker daemon, which runs inside the VM, rather than by the
host client.

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
  python /app/socket_probe.py /run/smol-compose-evaluation/host.sock host-to-vm-ok
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
machine stop and start. The current SmolVM agent does not automatically restart
`dockerd`, so run the detached `dockerd` command again after every machine
start. The Compose service uses `restart: unless-stopped`, allowing Docker to
restore it after the daemon starts.

This is the remaining lifecycle gap for using SmolVM as an unattended Compose
backend. A general agent-managed guest-service facility would remove it without
requiring systemd or another supervisor in the guest.

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
