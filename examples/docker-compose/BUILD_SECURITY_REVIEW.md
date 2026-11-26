# Untrusted build security review

Date: 2026-11-20. Result and TODOs only; no security controls implemented by this review.

Scope: SmolVM Compose runtime at `bfd8bfd4`, including the bundled-image identity fixes,
and the launcher's current derived-image integration based on `5cef1bbb` plus working-copy
review fixes. This evaluates hostile Dockerfiles, dependencies and build configuration.
It is a source/configuration review, not a penetration test or a complete vulnerability
audit of Docker, BuildKit, the guest kernel or libkrun.

## Result

The current setup is a shared development runtime, not an established isolation boundary
between mutually untrusted projects. An ordinary Dockerfile can execute arbitrary code
inside its build steps, read supplied inputs, use available network access, consume shared
resources, and access matching persistent cache mounts. Those capabilities need no escape.

It does **not** automatically receive the Docker socket, the Mac filesystem, or the
privileges of the outer BuildKit daemon container. However, a successful escape into that
privileged daemon or the guest kernel should be treated as compromise of the shared VM.
In the launcher, that puts other workloads, their persistent data, and the writable host
stacks directory at risk. The VM boundary still matters for the rest of macOS; it does
not protect files deliberately shared into the VM.

Recommendation: do not advertise builds from arbitrary repositories as safely isolated
from the user's other projects until the P1 decisions and validation below are resolved.

## Observed configuration

| Boundary | Current configuration | Implication |
| --- | --- | --- |
| Builder daemon | `builder/prepare-builder.sh` creates `buildx_buildkit_xe0` with `--privileged --init`, as root by default | Daemon compromise has a large guest-level blast radius. This privilege is not automatically granted to each Dockerfile `RUN`. |
| Build entitlements | Daemon allows `network.host`; it does not explicitly allow `security.insecure` or `device` | Host-network requests have the daemon-side permission available. Other insecure requests should be rejected; verify on the exact shipped version. |
| Builder lifetime | One named builder and one persistent `${builder}_state` volume | Projects share a daemon and cache state across builds and VM restarts. `restart=no` prevents automatic startup, not persistence. |
| Builder mounts | Persistent BuildKit state plus read-only `buildkitd.toml`; no Docker socket or `/stacks` bind in its creation command | Ordinary steps do not gain arbitrary guest filesystem access from those host VM mounts alone. |
| Build networking | VM has `net=true`; worker network mode is unspecified | No explicit untrusted-build egress policy. Effective routes and worker namespaces need measurement. |
| Docker API | DinD listens on `/var/run/docker.sock`, exposed to the Mac over the configured socket bridge | No unauthenticated Docker TCP listener is requested. Possession of the Docker API is nevertheless a powerful guest control capability. |
| Resource controls | VM CPU/RAM/disk limits; BuildKit `max-parallelism=2`, `gc=false`; no builder container CPU, memory or PID limits in its creation command | Parallelism limits build scheduling, not the processes or memory created by one malicious step. |
| Launcher host share | `SmolVMSetup.swift` mounts the configured stacks directory at `/stacks:rw` | Guest compromise can threaten all host files in that share, subject to the host process's filesystem permissions. |
| Launcher client authority | `ContainerBuildTools.swift` copies Docker client configuration including credentials/proxies; `ComposeServer.swift` runs with the user's home and inherited environment | The host-side build session and configuration require their own trust policy. They are not confined by the guest VM. |

## What a Dockerfile can attack without an escape

### Inputs and credentials

Every supplied context should be treated as readable by the build. A malicious step can
copy sensitive inputs into its output, logs or a network request. Context selection and
`.dockerignore` determine the input boundary; `COPY ../...` is not a general host-file
escape. A Dockerfile bind mount takes its source from a context, stage or image, rather
than granting an arbitrary bind of the Mac or guest filesystem.
[Docker build contexts](https://docs.docker.com/build/concepts/context/),
[Dockerfile mount semantics](https://docs.docker.com/reference/dockerfile/#run---mounttypebind).

Secrets and SSH access deliberately supplied to a build are usable by malicious build
code. Secret mounts avoid automatic inclusion in layers, but cannot stop a step from
copying or transmitting their contents. SSH-agent forwarding generally exposes signing
capability rather than private-key bytes; that capability can still be abused during the
session. No automatic SSH-agent forwarding was found in the reviewed builder creation.
[Build secrets](https://docs.docker.com/build/building/secrets/).

The copied host Docker configuration is not itself mounted into each `RUN`. Registry
authentication is mediated by Docker/BuildKit sessions; do not equate it with unrestricted
access to the credentials file. Separately, Docker client proxy settings can automatically
populate proxy build arguments, including credentials embedded in proxy URLs. Inspect the
effective client settings before claiming that a build receives no credentials.
[Docker proxy configuration](https://docs.docker.com/engine/cli/proxy/).

### Network access

Assume a step can exfiltrate supplied inputs to reachable destinations unless an enforced
policy prevents it. It can also probe or attack reachable guest services and remote
services. Network reachability to Mac services, LAN/VPN addresses, link-local metadata
endpoints and other containers is not yet established by security tests.

The launcher's machine specification supplies no CIDR/hostname restriction. SmolVM's
`NetworkPolicy::Egress` documents omitted CIDRs as unrestricted, but the actual backend
may still impose special-address restrictions. Do not claim either universal host access
or effective host isolation without testing that backend.

`network.host` must be authorized by both the daemon and the build request. A Dockerfile
alone does not bypass that gate. Here the daemon side is already enabled, and the host
Buildx wrapper forwards caller arguments. “Host” in BuildKit means its worker's network
namespace, not automatically the Mac's: the builder container has no `--network=host`.
[Buildx entitlements](https://docs.docker.com/reference/cli/docker/buildx/build/#allow).

Restricting `RUN` networking alone does not establish an offline build: frontend images,
base images, remote contexts and other source resolution can require daemon-side fetches.
The existing zero-outbound first-build test uses a controlled scratch build; it is not a
network policy for attacker-controlled Dockerfiles.

### Shared caches and output

BuildKit cache-mount IDs are chosen by Dockerfiles, with shared access the default. On this
single builder, another project can request a known ID and attempt to read or modify that
cache. Package caches must not contain secrets or be trusted as untampered input. A
Compose project name is not a demonstrated cache isolation boundary; `sharing=locked`
serializes writers and does not establish authorization.
[Dockerfile cache mounts](https://docs.docker.com/reference/dockerfile/#run---mounttypecache).

The build can intentionally produce a malicious image or executable. Loading its image
does not itself execute its entrypoint. Running the result, publishing it, exporting files
to the host, or consuming poisoned dependencies in a later trusted build are separate
trust transitions. Build cache can retain source and intermediate results; exported cache
can expose data copied into those layers.
[Cache backends](https://docs.docker.com/build/cache/backends/).

### Availability

A build step can consume CPU, fork processes, allocate memory, produce excessive logs,
fill cache/snapshots and keep builds busy indefinitely. The shared VM's limits bound some
host consumption but do not reserve resources for other services. The launcher runs
Docker, routing and user applications in the same VM. Cache maintenance and
`max-parallelism=2` are not per-build quotas; disabled automatic GC increases reliance on
external cleanup keeping pace.

## What requires more authority or an isolation failure

| Target | Required capability or failure |
| --- | --- |
| Arbitrary Mac files outside the supplied contexts | Additional host-side file grants, unsafe Compose/Bake context or exporter settings accepted by the client, a client/session vulnerability, or a VM/host escape. A plain `COPY` is insufficient. |
| Guest Docker socket and sibling containers | Explicit socket exposure, access to an exposed management service, or an escape from build execution into a sufficiently privileged guest context. |
| Host `/stacks` contents beyond the build context | A client that supplies those files, a Compose runtime bind mount, or guest compromise. The VM share alone is not a normal Dockerfile mount grant. |
| Guest-wide root privileges | Insecure execution explicitly enabled at both entitlement layers, or a BuildKit/runtime/kernel isolation vulnerability. The outer privileged builder substantially increases the impact of daemon compromise. |
| Host OS execution | A host-side client vulnerability, VM device/hypervisor escape, or later host execution of attacker-modified shared files. Guest root is not automatically macOS root. |

Docker daemon access must be treated as administrative authority over the daemon's host
environment. Here that environment is the guest, including whatever host paths are shared
into it. The privileged builder also shares the guest kernel with other workloads.
[Docker Engine security](https://docs.docker.com/engine/security/).

## Dockerfile trust versus whole-repository trust

Approving a Dockerfile with fixed caller-controlled inputs is narrower than accepting a
repository's Compose/Bake configuration or running its scripts. Compose build settings can
select contexts, additional contexts, arguments, secrets, SSH access and entitlements.
The client runs on the Mac, so client-side path resolution must be checked independently
of guest mounts. Exact enforcement in the shipped Compose server was not audited here;
the separate local Compose checkout is not proof of the released binary's behavior.
[Compose build specification](https://docs.docker.com/reference/compose-file/build/).

Likewise, a malicious service definition accepted by `compose up` may request guest bind
mounts, devices, privileged containers or the Docker socket. That is a runtime permission
decision, not a Dockerfile escape. Repository scripts executed on macOS run with whatever
authority the host caller gives them. Neither is made safe by pinning BuildKit's image.

## TODOs — no implementation in this review

- [ ] **P1 — Define supported trust levels.** Document whether arbitrary untrusted builds
  are supported. Distinguish a fixed Dockerfile build from accepting Compose/Bake options,
  running repository scripts, and starting the resulting services. Owner: launcher/product.
- [ ] **P1 — Decide the isolation boundary.** Evaluate a disposable build VM per untrusted
  job or trust group, with only required inputs and no writable stacks share or user
  workloads. Separate builders inside one VM improve cache separation but still share its
  kernel. Record cost/startup measurements before choosing. Owner: launcher/runtime.
- [ ] **P1 — Measure and constrain egress.** Test controlled endpoints on IPv4/IPv6,
  guest/container networks, Mac-facing routes, LAN/VPN and link-local ranges. Cover default
  builds and host-network requests, source fetches and custom frontends. Enforce selected
  policy at the network boundary rather than trusting Dockerfile instructions. Owner: runtime.
- [ ] **P1 — Review effective build grants.** Audit the shipped Compose server and Buildx
  invocation for absolute/parent contexts, extra contexts, exports, caches, secrets, SSH,
  inherited build arguments, proxies and entitlement flags. Reject or explicitly authorize
  grants outside the chosen trust level. Owner: host client.
- [ ] **P1 — Prove cache separation or stop sharing across trust groups.** Use two projects
  with the same cache ID and sentinel files; test disclosure and modification. Select an
  actual trust boundary, not a repository-chosen ID or a concurrency lock. Owner: runtime.
- [ ] **P1 — Bound denial of service.** Test memory/PID/disk/log exhaustion and cancellation
  in a disposable environment. Define quotas, deadlines and reserved capacity for live
  services using Docker/VM controls. Confirm cleanup after crash and timeout. Owner: runtime.
- [ ] **P2 — Reduce daemon privilege where supported.** Evaluate BuildKit's supported
  rootless/isolation modes and remove unused insecure entitlements. Verify build features,
  storage and performance before changing defaults; do not invent another sandbox engine.
- [ ] **P2 — Validate denied capabilities.** Test that ordinary steps cannot open the Docker
  socket, enumerate sibling files, mount guest disks, access unsupplied host files, or use
  `security.insecure`/devices without authorization. Verify the exact shipped configuration.
- [ ] **P2 — Audit the second boundary.** Review libkrun/virtiofs/vsock exposure and host
  process confinement. A guest compromise must not be assumed contained merely because a
  VM exists. Include the writable share and later host execution of modified files.
- [ ] **P2 — Establish patch and frontend policy.** Track advisories for the pinned Docker,
  BuildKit, runtimes, kernel and VM stack. Review permitted Dockerfile frontends and registry
  sources. Digest pinning gives repeatability, not proof that code is safe or patched.
- [ ] **P2 — Protect outputs and session data.** Review registry push/cache-export authority,
  host exporter destinations, log redaction and retention of contexts/intermediates. Never
  supply reusable credentials to a hostile build based only on secret-mount semantics.

Keep Docker/BuildKit responsible for image verification, build namespaces and entitlement
enforcement. The launcher/runtime owns deciding which inputs, capabilities, network and
persistent state an untrusted job is granted. Avoid custom Dockerfile parsing as a security
boundary; shell commands, dependencies and custom frontends defeat simple instruction lists.

## Validation status

Observed from source: privileged daemon creation, entitlement flags, persistent shared
builder, configured mounts, absent per-builder resource limits, host client configuration
copying and the launcher's writable stacks share. Attack consequences above are threat
model conclusions; no successful container or VM escape is claimed.

Earlier functional tests exercised offline first-build behavior, upload integrity,
restarts and Docker-assigned image identity. They do not test malicious-code containment.
No adversarial network, cache-isolation, exhaustion or escape experiments were run for
this document. Those are explicitly pending TODOs.
