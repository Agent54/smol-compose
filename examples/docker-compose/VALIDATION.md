# Validation record

This example originated as an Apple Silicon feasibility evaluation outside the
smolvm checkout. It was moved here so the exact Compose, mount, port, and socket
fixtures can be maintained alongside the existing Docker-in-VM example.

## Current branch validation

The maintained example was run end-to-end on Apple Silicon macOS on 2026-08-17
with Docker Engine 28.5.2 and `overlay2`:

- a normal Smolfile-created machine auto-started Docker without a manual
  `dockerd` command;
- host `docker-compose` reached Docker through
  `examples/docker-compose/.state/docker.sock`;
- the TCP probe and both arbitrary Unix-socket directions passed before and
  after a full VM stop/start;
- `pack create` produced a signed launcher and a compressed `.smolmachine` in
  `examples/docker-compose/.state/`; and
- a fresh machine created from that artifact started without pulling
  `docker:28-dind`, auto-started Docker, and passed the same Compose, TCP, and
  bidirectional socket probes.

All runtime databases, disks, build staging, artifacts, logs, and Unix sockets
used for this validation were kept below the example's ignored `.state`
directory.

## Provenance

- evaluated smolvm `main`: `e2e04fa1d55190bc7fd4144b5bae29b3d870b8d4`;
- released Linux agent/rootfs: SmolVM 1.7.5;
- evaluated libkrun: `3ca804246b584d8024f95fd3e8ca48daa3e38800`;
- guest: Alpine Linux 3.19, Linux 6.12.95, aarch64;
- Docker Engine: 25.0.5 with `overlay2` on ext4;
- host: Apple Silicon macOS.

## Successfully validated

- the VM remained reachable with virtio-net enabled;
- host `docker-compose` controlled the in-VM Docker daemon through
  `examples/docker-compose/.state/docker.sock`;
- host port `18080` reached container port `8080`;
- files from the dedicated host fixture directory were bind-mounted into the
  Compose container through the VM;
- a host Unix socket was proxied into the VM and mounted into the container;
- a socket created by the Compose container was proxied back to the host; and
- Docker images and container metadata persisted on the ext4 storage disk.

## Issues found during evaluation

1. The released 1.7.5 macOS libkrun did not export
   `krun_add_net_unixstream`. A current libkrun build with `NET=1` was required
   for virtio-net and published ports.
2. Building libkrun on macOS required a static Linux-musl `krun-init`. Without
   the musl target, the fallback embedded a macOS executable and the guest
   exited before the agent became ready.
3. SmolVM runtime socket paths can exceed macOS `SUN_LEN`. A real short runtime
   path worked; a symlink to a longer path did not because paths are
   canonicalized.
4. The released installation lacked preformatted ext4 templates and therefore
   needed host `mkfs.ext4`. Current release packaging creates storage and
   overlay templates, so this should be a build-time dependency only.
5. The original bare-VM fixture installed Docker with one-time init commands,
   so a background `dockerd` process did not survive a VM stop and start. The
   maintained example now uses the DinD image as the persistent workload;
   SmolVM relaunches its entrypoint on every machine start.

## Improvements adopted from `docker-in-vm`

The existing `examples/docker-in-vm/docker.smolfile` provides a more complete
explanation of the kernel and nested-overlay requirements. Most importantly,
it documents using:

```text
dockerd --data-root=/storage/docker --storage-driver=overlay2
```

This Compose example uses that form directly. It is better than bind-mounting
`/storage/docker` onto `/var/lib/docker` because the data-root setting belongs
to the daemon and remains correct after every VM restart.

## Coverage added by this example

The Docker-in-VM example validates Docker Engine itself but does not exercise a
Compose application, the outer VM port mapping, or arbitrary Unix-socket
proxies in both directions. This example adds those integration paths while
reusing its storage guidance.
