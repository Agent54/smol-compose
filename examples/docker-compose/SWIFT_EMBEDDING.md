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

Pin a release tag and download these three files during the application build
or release process:

- `smolvm-<version>-darwin-arm64.tar.gz`
- `smolvm-<version>-docker-compose-darwin-arm64.smolmachine`
- `checksums.sha256`

Verify both artifacts against `checksums.sha256`. The normal distribution and
the Compose sidecar must come from the same release. Do not download `latest`
when the application starts.

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
      |  |- libkrunfw.5.dylib
      |  `- libkrunfw.dylib -> libkrunfw.5.dylib
      `- docker-compose.smolmachine
```

Both release assets are required. The distribution contains the macOS runtime,
the network-enabled libkrun build, the agent rootfs, and disk templates. The
`.smolmachine` contains the already-resolved Docker image layers and workload
configuration. The Swift project should not build libkrun or the Docker image.

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

On first launch, execute the equivalent of:

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

The packed Docker image contains the Compose v2 CLI plugin, so the Swift app
does not need a host `docker` or `docker-compose` executable.

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
