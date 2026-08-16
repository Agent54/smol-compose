# Agent handoff: non-obvious context

Read this before continuing work on this example. It records conversation and
workspace context that is not reliably inferable from the repository source or
the example documentation.

## User intent and working constraints

The end goal is a Docker Compose backend embedded in a macOS Apple Silicon
Swift application. The application must ship everything it needs; end users
must not install SmolVM, Homebrew packages, a Docker daemon, or build tools.

The user has specifically asked for:

- host TCP ports published through the VM to Compose containers;
- a dedicated, user-selected host project directory mounted into the VM and
  usable as a Compose bind-mount source;
- arbitrary Unix sockets proxied host-to-VM and VM-to-host;
- persistent Docker images, containers, volumes, and project data;
- a reviewable GitHub fork/release workflow suitable for eventual upstream PRs;
- simple, individually reviewable commands, with no wrapper shell scripts,
  chained shell logic, hidden cleanup, or destructive host operations.

Do not modify SmolVM runtime source merely to improve this example unless the
user explicitly authorizes implementing a runtime feature. A previous turn
unexpectedly started implementing boot-service behavior in SmolVM source and
the user required it to be undone. At the start of the example move, the
SmolVM worktree was clean.

Do not automatically start, stop, delete, or recreate the user's existing VM.
Show any mutating commands plainly and let the user review them first unless
they explicitly ask the agent to execute them.

## Workspace layout and Git state

The workspace root is:

```text
/Users/jan/Dev/xe/microsandbox
```

Neither the workspace root nor its `smol/` directory is a Git repository. The
actual SmolVM repository is:

```text
/Users/jan/Dev/xe/microsandbox/smol/smolvm
```

The root-level Deno files, `test.ts`, `node_modules`, `test/`, and the separate
`microsandbox-latest/` checkout belong to the competing Microsandbox
evaluation. They are not the Swift application and should not be used as the
implementation to extend.

The durable Smol evaluation files previously lived directly under `smol/`.
They were moved into this example. Generated state remains under `smol/.state`
and must not be committed. It was approximately 4 GiB when inspected.

At the time this summary was created, the intended SmolVM worktree changes
were only example/documentation changes:

```text
M  examples/README.md
M  examples/docker-in-vm/docker.smolfile
?? examples/docker-compose/
```

No commit has been created. Recheck `git status --short` before doing further
work because the user may have changed the tree after this handoff.

## Existing locally working runtime

The successful feasibility run used a hybrid runtime:

- host CLI from SmolVM `main` commit
  `e2e04fa1d55190bc7fd4144b5bae29b3d870b8d4`;
- Linux agent/rootfs from released SmolVM 1.7.5;
- locally built libkrun commit
  `3ca804246b584d8024f95fd3e8ca48daa3e38800` with `BLK=1 NET=1 GPU=0`;
- existing machine name `smol-compose-dev`.

The local runtime paths used for that successful machine were:

```text
HOME=/Users/jan/Dev/xe/microsandbox/smol/.state/d
DYLD_LIBRARY_PATH=/Users/jan/Dev/xe/microsandbox/smol/.state/dev-lib
SMOLVM_AGENT_ROOTFS=/Users/jan/Dev/xe/microsandbox/smol/.state/release-home/Library/Application Support/smolvm/agent-rootfs
SMOLVM=/Users/jan/Dev/xe/microsandbox/smol/smolvm/target/release/smolvm
```

Do not assume the existing machine is currently running or healthy. Inspect it
using the same environment before interpreting its state. Do not mix the
default host HOME with this short HOME: SmolVM will look in a different machine
database and report that the machine does not exist or is stopped.

The new documented example uses the distinct name
`docker-compose-evaluation`; it has not been run end-to-end since the files
were moved.

## Failure history and correct interpretations

These points consumed significant debugging time and should not be rediscovered
from scratch:

1. Released SmolVM 1.7.5's macOS libkrun lacked
   `krun_add_net_unixstream`. TSI could provide outbound networking but could
   not publish host ports. A libkrun build with `NET=1` was required for
   virtio-net.
2. Building libkrun without the Rust target
   `aarch64-unknown-linux-musl` caused the fallback init build to embed a macOS
   Mach-O executable in the guest. The VM then exited with code 0 before the
   agent became ready. LLVM's `libclang.dylib` and `lld` were also needed for
   the local libkrun build.
3. macOS Unix-socket paths exceeded `SUN_LEN`. Setting only
   `SMOLVM_CONTROL_SOCKET` did not solve every socket because the agent socket
   was still derived from SmolVM's data/cache path. A real short HOME fixed the
   problem. A symlink to a long directory did not help because paths were
   canonicalized.
4. `krun_start_enter` returning `-22` occurred after unclean/unreachable VM
   state and can mean a held or invalid disk/configuration. Do not immediately
   delete disks; first verify the old VM process has fully exited and that the
   same HOME/runtime is being used.
5. `curl: connection reset by peer` was observed when no Compose container was
   running. `docker ps` was empty, so that error was not evidence that outer
   port forwarding had failed.
6. Detached `dockerd` initially returned a PID but immediately failed because
   `/var/lib/docker` was no longer bound to ext4. Detached exec itself was not
   the problem.
7. The one-time init commands did not run again after VM restart. `/run` is
   tmpfs, mount namespaces are recreated, and background processes do not
   survive a VM stop. The working recovery was to reapply the ext4 bind and
   relaunch `dockerd`. This example now avoids the bind entirely by using
   `--data-root=/storage/docker`.
8. `e2fsprogs` was required on the development host only because the installed
   1.7.5 runtime lacked preformatted storage templates. SmolVM's current
   release builder creates compressed storage and overlay templates. A final
   embedded distribution should bundle those and must not require end-user
   `mkfs.ext4`.

## Docker and Compose behavior that matters

There are two separate port-publishing layers:

```text
container port -> VM port -> macOS host port
```

Compose publishes the first layer. SmolVM must declare the second layer when
the machine is created. Ports dynamically selected later by Compose or
Testcontainers are not automatically exposed across the outer VM boundary.

When host Compose talks to the guest daemon through `DOCKER_HOST`, Docker bind
sources are resolved by the daemon inside the VM. Therefore the Compose file
uses `/workspace/smol/docker-compose/fixtures/...`, not the corresponding
macOS path. The host fixture directory reaches that guest location through
SmolVM virtiofs.

SmolVM host mounts accept directories, not individual files. Compose may still
bind individual files or subdirectories from the mounted guest directory into
containers.

The socket directions are easy to confuse:

- `--mount-socket HOST:GUEST` makes a host-listening Unix socket available to
  guest applications;
- `--expose-socket GUEST:HOST` makes a guest-listening Unix socket available to
  host applications;
- `--docker-socket` is the specialized guest-to-host bridge for the guest's
  `/var/run/docker.sock`; it does not expose the host Docker daemon to the VM.

A normal virtiofs directory mount does not proxy Unix-socket semantics. Socket
files require the explicit vsock-backed socket bridge.

Docker state belongs directly on `/storage/docker`, the VM's persistent ext4
disk. The root filesystem is already overlayfs, so Docker `overlay2` must not
place its upper layers there.

The current remaining lifecycle gap is automatic daemon startup. After every
VM start, `dockerd` must currently be launched again. The preferred upstream
direction is an agent-managed, generic persistent guest-service facility—not
systemd, supervisord, or a Docker-only special case. This is a proposal, not an
implemented or approved source change.

## SDK, API, and Swift integration findings

There is currently no official Swift SDK, stable C ABI, Swift package, or
XCFramework for SmolVM.

The public `smolmachines` embedded SDK targets Node/TypeScript and Python. Its
documented local configuration covers mounts and ports but does not expose the
complete socket functionality needed by this backend. In the evaluated source:

- the embedded SDK did not expose `dockerSocket`, `mount-socket`, or
  `expose-socket` configuration;
- the REST create API exposed `dockerSocket` but not arbitrary published
  sockets;
- the CLI was the only complete interface for both arbitrary socket
  directions.

The local `smolvm serve` REST API is not normally authenticated. A protected
Unix socket limits access by filesystem/process boundaries, and development
source contains optional fleet mTLS, but there is no per-machine token or RBAC.
Anyone able to call the machine API can control the VM capabilities granted to
the SmolVM process.

The practical Swift recommendation was therefore:

- bundle a signed `smolvm` helper, compatible libkrun/libkrunfw, agent rootfs,
  disk templates, and a Docker-capable guest artifact inside one `.app`;
- invoke the helper with Swift `Process` and an argument array—never shell
  command strings;
- keep VM operations behind a typed Swift actor;
- optionally place that controller behind a signed XPC service when crash
  isolation, background lifetime, or untrusted UI/plugin code requires it;
- do not expose `smolvm serve` merely to connect the Swift UI;
- give only the process that invokes Hypervisor.framework the
  `com.apple.security.hypervisor` entitlement;
- use security-scoped bookmarks for a user-selected dedicated project folder
  and retain access for the lifetime of the VM mount.

Literal same-process Swift embedding would require a new Rust C ABI and an
XCFramework. That is possible but would be a maintained fork surface and was
not recommended as the first production integration.

## GitHub and release direction

The proposed repository boundary is:

- a small fork of `smol-machines/smolvm` containing only reusable runtime,
  tests, examples, API parity, and release packaging;
- a separate Swift application repository containing the XPC/Process wrapper,
  app entitlements, user-folder policy, Compose orchestration, and app bundle
  assembly.

The Swift app CI should download an exact tagged release from the fork, verify
a committed SHA-256, stage the runtime into the app, sign nested code, then sign
and notarize the outer application. It should never consume `latest` or build
Rust/libkrun during the app bundle job.

Potential upstream work should be split into reviewable PRs:

1. Docker/Compose example and integration coverage;
2. generic agent-managed guest services for boot/restart;
3. REST and embedded-SDK parity for Docker and arbitrary socket bridges;
4. an optional Docker/Compose guest artifact, rather than adding Docker to
   every base agent rootfs.

Do not put Swift application code or app-specific policy into the SmolVM fork.

## Verification status of this moved example

The original external fixture passed end-to-end. After moving and improving it:

- `git diff --check` passed;
- documented paths were reviewed for the new example location;
- the fixture now uses direct Docker data-root and Compose
  `restart: unless-stopped`;
- the guest fixture removes only its own known socket path before rebinding;
- a requested `docker-compose ... config` verification command was declined by
  the host and was not retried;
- the moved example has not yet been rerun against the VM.

Before claiming that the new example works, run the documented flow with user
approval and record the exact SmolVM/libkrun/agent versions used.
