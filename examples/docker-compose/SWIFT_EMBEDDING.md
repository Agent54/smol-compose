# Embedding the Docker Compose backend in a Swift app

This guide describes how a macOS Apple Silicon Swift manager can ship and
control the SmolVM Docker Compose backend without requiring Docker Desktop, a
host Docker daemon, a Docker SDK, a Rust toolchain, or third-party Swift
dependencies.

The recommended control path is:

```text
Swift app -> bundled smolvm-bin -> embedded Docker .smolmachine
                                  |- dockerd starts automatically
                                  `- docker compose runs inside the VM
```

The exact lifecycle, port, and socket flags are implemented by `smolvm`, the
lower-level runtime shipped as part of Smol. Invoke `smolvm-bin` directly from
Swift with `Foundation.Process` and an argument array. Do not construct shell
command strings.

## Release assets

Select the [latest release](https://github.com/Agent54/smol-compose/releases/latest),
record its tag in the application's build configuration, and download these
files during the application build or release process:

- `smolvm-<version>-darwin-arm64.tar.gz`
- `smolvm-<version>-docker-compose-darwin-arm64.smolmachine`
- `checksums.sha256`

Verify both artifacts against `checksums.sha256`. The normal distribution and
the Compose sidecar must come from the same release. Do not download `latest`
when the application starts.

For embedded build support, also obtain the matching
`.smolmachine.builder.lock` and check its metadata against the application's
requirements. See the [release asset guidance](README.md#release-asset-boundary).
The release's checksum file supplies the artifact digests.

After verifying the versioned sidecar, copy it into the application bundle as
`docker-compose.smolmachine`. All paths and Swift examples below use that stable
bundled name. An application that preserves the versioned release filename must
instead resolve that exact filename everywhere the examples refer to
`docker-compose.smolmachine`.

Preserve the extracted distribution layout in the application bundle:

```text
MyManager.app/
`- Contents/
   |- MacOS/MyManager
   `- Helpers/SmolRuntime/
      |- smolvm-bin
      |- smolvm
      |- agent-rootfs/
      |- storage-template.ext4
      |- overlay-template.ext4
      |- lib/
      |  |- libkrun.dylib
      |  |- libkrun.2.dylib -> libkrun.dylib
      |  |- libkrunfw.5.dylib
      |  |- libkrunfw.dylib -> libkrunfw.5.dylib
      |  |- libepoxy.0.dylib
      |  |- libvirglrenderer.1.dylib
      |  `- libMoltenVK.dylib
      `- docker-compose.smolmachine
```

Preserve the whole extracted distribution rather than selecting individual
dylibs. In particular, `smolvm-bin` is linked against the versioned
`libkrun.2.dylib` name; omitting that symlink prevents the helper from starting.

Both release assets are required. The distribution contains the macOS runtime,
the agent rootfs, disk templates, and the fork's pinned libkrun build compiled
with `BLK=1 NET=1 GPU=1`. `NET=1` provides
`krun_add_net_unixstream`, which SmolVM uses for virtio-net and the Unix socket
bridges required by this backend. That library also embeds `krun-init` built as
a static `aarch64-unknown-linux-musl` executable, so the guest init is Linux
code with no unavailable dynamic runtime dependency rather than a macOS or
dynamically linked executable.

The `.smolmachine` contains the already-resolved Docker image layers and
workload configuration. Together, these release assets are the distributable
form of the earlier development proof that selected a newly built
`libkrun.dylib` through `DYLD_LIBRARY_PATH`: the app still points the loader at
its bundled `lib/` directory, but it no longer substitutes an unpublished
development library. The Swift project should not build libkrun, krun-init, or
the Docker image.

## Runtime environment

Call `smolvm-bin` rather than passing user input through the `smolvm` shell
wrapper. Give every command component its own `Process.arguments` entry.

Set an explicit environment for every invocation:

```swift
let runtime = Bundle.main.bundleURL
    .appendingPathComponent("Contents/Helpers/SmolRuntime")
let state = try appSupportDirectory()
    .appendingPathComponent("SmolState")

process.executableURL = runtime.appendingPathComponent("smolvm-bin")
process.environment = [
    "HOME": NSHomeDirectory(),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "TMPDIR": state.appendingPathComponent("tmp").path,
    "SMOLVM_DATA_DIR": state.path,
    "SMOLVM_LIB_DIR": runtime.appendingPathComponent("lib").path,
    "SMOLVM_AGENT_ROOTFS": runtime.appendingPathComponent("agent-rootfs").path,
    "DYLD_LIBRARY_PATH": runtime.appendingPathComponent("lib").path,
]
```

Create `state`, `state/tmp`, `state/sockets`, and `state/projects` before the
first command. Use permissions `0700` for the private state and socket
directories. Because the app invokes `smolvm-bin` directly, keep
`DYLD_LIBRARY_PATH` pointed at the bundled `lib/` directory on every call.

Serialize create, start, stop, update, and delete operations in a Swift actor.
When stdout and stderr use pipes, drain both concurrently so a full pipe cannot
deadlock the child process.

## Application state and sockets

Use an application-owned persistent directory:

```text
~/Library/Application Support/<short-app-name>/SmolState/
|- sockets/
|  |- docker.sock
|  |- manager-to-vm.sock
|  `- vm-to-manager.sock
|- projects/
`- tmp/
```

Create the state and socket directories with mode `0700`. Keep
`SMOLVM_DATA_DIR` short: macOS Unix-domain socket paths are limited to roughly
104 bytes, and SmolVM creates internal socket suffixes below the data directory.
Validate UTF-8 byte length rather than Swift character count.

Never delete a path taken directly from an environment variable. Model every
removable socket as a hard-coded suffix:

```swift
enum OwnedSocket: String {
    case docker = "docker.sock"
    case managerToVM = "manager-to-vm.sock"
    case vmToManager = "vm-to-manager.sock"
}

func socketURL(_ socket: OwnedSocket, under directory: URL) -> URL {
    directory.appendingPathComponent(socket.rawValue)
}
```

Before removing a stale socket, verify that its standardized parent is exactly
the private sockets directory and its final component is one of these enum
values. Do not recursively delete the state directory during normal startup or
shutdown.

## Create the persistent Docker machine

One Docker machine can host multiple Compose projects. Assign every project a
stable, unique Compose project name.

The smallest dependency-free setup needs only the embedded sidecar, outbound
VM networking, and the app-owned project mount:

```sh
smolvm-bin machine create \
  --name mymanager-docker \
  --from /path/to/SmolRuntime/docker-compose.smolmachine \
  --net-backend virtio-net \
  --volume /path/to/SmolState/projects:/workspace/projects \
  --label com.example.owner=mymanager
```

Use this minimal form when Swift controls Compose exclusively with `machine
exec`. Add `--port`, `--mount-socket`, and `--expose-socket` only for concrete
application capabilities. Project container images are not part of the Docker
runtime sidecar, so `virtio-net` also lets Compose pull those images on first
use.

For an application that needs the validated host port and both arbitrary socket
directions, execute the equivalent of:

```sh
smolvm-bin machine create \
  --name mymanager-docker \
  --from /path/to/SmolRuntime/docker-compose.smolmachine \
  --net-backend virtio-net \
  --volume /path/to/SmolState/projects:/workspace/projects \
  --port 18080:8080 \
  --expose-socket /var/run/docker.sock:/path/to/SmolState/sockets/docker.sock \
  --mount-socket /path/to/SmolState/sockets/manager-to-vm.sock:/run/mymanager/manager.sock \
  --expose-socket /run/mymanager/service.sock:/path/to/SmolState/sockets/vm-to-manager.sock \
  --label com.example.owner=mymanager
```

The corresponding Swift argument array is:

```swift
let arguments = [
    "machine", "create",
    "--name", "mymanager-docker",
    "--from", runtime.appendingPathComponent("docker-compose.smolmachine").path,
    "--net-backend", "virtio-net",
    "--volume", "\(projectsDirectory.path):/workspace/projects",
    "--port", "18080:8080",
    "--expose-socket",
        "/var/run/docker.sock:\(socketURL(.docker, under: socketsDirectory).path)",
    "--mount-socket",
        "\(socketURL(.managerToVM, under: socketsDirectory).path):/run/mymanager/manager.sock",
    "--expose-socket",
        "/run/mymanager/service.sock:\(socketURL(.vmToManager, under: socketsDirectory).path)",
    "--label", "com.example.owner=mymanager",
]
```

Use `machine ls --json` to determine whether the app-owned machine already
exists. Do not assume that every `machine create` failure means it exists.

Socket direction and purpose:

| Purpose | Direction | Flag |
| --- | --- | --- |
| Docker daemon available to macOS | VM to host | `--expose-socket /var/run/docker.sock:<host>` |
| Swift-owned service available to Compose | host to VM | `--mount-socket <host>:<guest>` |
| Compose service available to Swift | VM to host | `--expose-socket <guest>:<host>` |

Exposing `docker.sock` is optional when the app controls Compose exclusively
through `machine exec`. Keep it only when the app needs Docker API compatibility
or must pass the socket to another host tool. Never expose dockerd over TCP.

## Start Docker and wait for readiness

Start the VM when the manager needs the backend:

```sh
smolvm-bin machine start --name mymanager-docker
```

The packed workload launches `/usr/local/bin/dockerd-entrypoint.sh`, which
starts dockerd on `/var/run/docker.sock` with persistent data in
`/storage/docker`. Poll for readiness for up to about 90 seconds:

```sh
smolvm-bin machine exec --name mymanager-docker -- \
  docker info --format '{{.ServerVersion}}'
```

Also make this an installation compatibility check:

```sh
smolvm-bin machine exec --name mymanager-docker -- docker compose version
```

The packed Docker image contains the Compose CLI plugin, so the Swift app
does not need a host `docker` or `docker-compose` executable.

## Minimal Swift integration sequence

The Swift-app agent can implement the first working integration in this order:

1. During the app build, download the matching release files above and
   verify the payloads against that release's `checksums.sha256`.
2. Extract the runtime archive into `Contents/Helpers/SmolRuntime`, preserve its
   entire layout, and copy the sidecar there as `docker-compose.smolmachine`.
3. At runtime, create the private application state directories and implement
   one `Foundation.Process` runner with the environment shown above.
4. Call `machine ls --json`; if the owned machine is absent, issue the minimal
   `machine create` command. Do not recreate an existing machine during normal
   startup.
5. Call `machine start`, then poll `machine exec -- docker info` until dockerd
   is ready. Check `machine exec -- docker compose version` once as an install
   compatibility assertion.
6. Put each Compose project below the mounted `projects` directory and run
   `docker compose up` through `machine exec` as shown below.
7. Use `machine stop` for normal shutdown. Reserve `machine delete` and Compose
   `down --volumes` for explicit destructive user actions.

That path uses only Foundation and the bundled release files. An XPC service,
host Docker socket, arbitrary socket bridges, and host port mappings can be
added later without changing the packaged Docker runtime.

## Run Compose projects

Write each project below the mounted host directory:

```text
SmolState/projects/web-stack/compose.yaml
SmolState/projects/web-stack/config/
SmolState/projects/web-stack/data/
```

The Docker daemon sees it at `/workspace/projects/web-stack`. Start it with:

```sh
smolvm-bin machine exec --name mymanager-docker -- \
  docker compose \
    --project-name web-stack \
    --project-directory /workspace/projects/web-stack \
    --file /workspace/projects/web-stack/compose.yaml \
    up --detach --wait --remove-orphans
```

Docker bind sources are resolved inside the VM. Compose files must therefore
refer to guest paths, not macOS paths:

```yaml
services:
  app:
    volumes:
      - /workspace/projects/web-stack/data:/app/data
      - /run/mymanager:/run/mymanager
```

The `/run/mymanager` mount lets a Compose container reach `manager.sock` and
create `service.sock` for the two arbitrary socket directions.

## Port forwarding

There are two forwarding layers. This Compose declaration publishes a
container on VM port 8080:

```yaml
services:
  web:
    ports:
      - "8080:8080"
```

The machine's `--port 18080:8080` mapping then publishes VM port 8080 on macOS.
The manager connects to `http://127.0.0.1:18080`.

Compose ports do not automatically create SmolVM host mappings. If project
ports change, stop the machine and use `machine update`, or recreate the
machine with the required outer mappings.

## Project lifecycle

Use the same `--project-name` and `--project-directory` on every command:

```sh
# JSON status
smolvm-bin machine exec --name mymanager-docker -- \
  docker compose --project-name web-stack \
  --project-directory /workspace/projects/web-stack ps --format json

# Streaming logs
smolvm-bin machine exec --stream --name mymanager-docker -- \
  docker compose --project-name web-stack \
  --project-directory /workspace/projects/web-stack logs --follow --no-color

# Stop without deleting the project
smolvm-bin machine exec --name mymanager-docker -- \
  docker compose --project-name web-stack \
  --project-directory /workspace/projects/web-stack stop

# Remove containers and networks
smolvm-bin machine exec --name mymanager-docker -- \
  docker compose --project-name web-stack \
  --project-directory /workspace/projects/web-stack down --remove-orphans
```

Only append `--volumes` following an explicit destructive user action. Stop the
VM with:

```sh
smolvm-bin machine stop --name mymanager-docker
```

Docker images, containers, and volumes persist under `/storage/docker` across
normal VM restarts. Services using `restart: unless-stopped` are restored by
Docker; otherwise the manager can issue the same idempotent `compose up` command
after Docker becomes ready.

Docker named volumes belong to the machine disk and can be lost if an
application upgrade deliberately deletes and recreates the machine. Put data
that must survive runtime replacement below the app-owned `projects` directory
and bind-mount its guest path into the service.

## Signing and process isolation

The executable which loads libkrun and invokes Hypervisor.framework needs the
entitlements from the repository's `smolvm.entitlements`:

```text
com.apple.security.hypervisor
com.apple.security.cs.disable-library-validation
com.apple.security.cs.allow-jit
```

Either preserve the signed release runtime or re-sign its nested executables
and dylibs with the application's Developer ID. If `smolvm-bin` is re-signed,
retain these entitlements and hardened runtime options.

For a production manager, a signed XPC service is a useful boundary:

```text
Swift UI -> typed XPC service -> smolvm-bin -> Docker VM
```

The XPC service can serialize lifecycle changes, own the child processes, and
keep VM/runtime failures out of the UI process. XPC and `Foundation.Process`
are Apple platform facilities and add no third-party application dependency.

An App Sandbox or Mac App Store build requires a separate entitlement and file
access review. Do not assume the Developer ID configuration is sufficient for
that distribution model.

## Security rules

- Keep host sockets below a mode-`0700` app-owned directory.
- Treat Docker socket access as control of the VM and every mounted host path.
- Do not accept arbitrary host mount or socket paths from untrusted Compose
  files.
- Never interpolate command arguments into a shell command.
- Do not expose the Docker daemon on TCP.
- Do not pass secret values as ordinary command-line arguments.
- Delete only explicitly enumerated app-owned socket paths and machine names.

The release artifact and socket behavior are verified by `verify.sh`. The
current verifier drives Compose through the exposed host Docker socket. An
embedding release should additionally assert `docker compose version` and run
at least one Compose command through `machine exec`, because that is the
dependency-free control path used by the Swift application.
