#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
STATE_DIR="$SCRIPT_DIR/.state"
SMOLVM_BIN="${SMOLVM:-$REPO_ROOT/target/release/smolvm}"
SMOLFILE="$SCRIPT_DIR/docker-compose.smolfile"
COMPOSE_FILE="$SCRIPT_DIR/compose.yaml"
RUN_ID="$(date +%s)-$$"
SOCKET_ID="$$"
case "$SOCKET_ID" in
    ''|*[!0-9]*)
        printf 'error: invalid numeric process identifier: %s\n' "$SOCKET_ID" >&2
        exit 1
        ;;
esac
NORMAL_MACHINE="compose-verify-$RUN_ID"
EMBEDDED_MACHINE="compose-embedded-$RUN_ID"
NORMAL_PORT="${SMOLVM_COMPOSE_PORT:-18080}"
EMBEDDED_PORT="${SMOLVM_COMPOSE_EMBEDDED_PORT:-18081}"
HOST_SOCKET="$STATE_DIR/verify-h-$SOCKET_ID.sock"
DOCKER_SOCKET="$STATE_DIR/verify-d-$SOCKET_ID.sock"
VM_SOCKET="$STATE_DIR/verify-v-$SOCKET_ID.sock"
EMBEDDED_DOCKER_SOCKET="$STATE_DIR/verify-ed-$SOCKET_ID.sock"
EMBEDDED_VM_SOCKET="$STATE_DIR/verify-ev-$SOCKET_ID.sock"
PACK_OUTPUT="$STATE_DIR/verify-pack-$SOCKET_ID.bin"
PACK_STAGING="$STATE_DIR/verify-pack-$SOCKET_ID.staging"
EMBEDDED_START_LOG="$STATE_DIR/verify-embedded-start-$SOCKET_ID.log"
KEEP_STATE="${KEEP_STATE:-0}"
EXPORT_PACK="${EXPORT_PACK:-0}"

case "$(uname -s)" in
    Darwin) PACK_HOST_OS="darwin" ;;
    Linux) PACK_HOST_OS="linux" ;;
    *)
        printf 'error: unsupported pack host operating system: %s\n' "$(uname -s)" >&2
        exit 1
        ;;
esac
case "$(uname -m)" in
    arm64|aarch64) PACK_HOST_ARCH="arm64" ;;
    x86_64|amd64) PACK_HOST_ARCH="amd64" ;;
    *)
        printf 'error: unsupported pack host architecture: %s\n' "$(uname -m)" >&2
        exit 1
        ;;
esac
EXPORTED_PACK="$STATE_DIR/docker-compose-runtime-${PACK_HOST_OS}-${PACK_HOST_ARCH}.smolmachine"

NORMAL_CREATED=0
NORMAL_RUNNING=0
NORMAL_COMPOSE=0
EMBEDDED_CREATED=0
EMBEDDED_RUNNING=0
EMBEDDED_COMPOSE=0
SOCAT_PID=""
SUCCESS=0

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

stop_machine() {
    local name="$1"
    "$SMOLVM_BIN" machine stop --name "$name"
}

delete_machine() {
    local name="$1"
    "$SMOLVM_BIN" machine delete --name "$name" --force >/dev/null 2>&1 || true
}

compose_for() {
    local socket_path="$1"
    shift
    DOCKER_HOST="unix://$socket_path" "${COMPOSE[@]}" -f "$COMPOSE_FILE" "$@"
}

cleanup() {
    set +e
    if [[ "$EMBEDDED_COMPOSE" == 1 && "$EMBEDDED_RUNNING" == 1 ]]; then
        compose_for "$EMBEDDED_DOCKER_SOCKET" down --remove-orphans >/dev/null 2>&1
    fi
    if [[ "$NORMAL_COMPOSE" == 1 && "$NORMAL_RUNNING" == 1 ]]; then
        compose_for "$DOCKER_SOCKET" down --remove-orphans >/dev/null 2>&1
    fi
    if [[ "$EMBEDDED_RUNNING" == 1 ]]; then
        stop_machine "$EMBEDDED_MACHINE" >/dev/null 2>&1 || true
    fi
    if [[ "$NORMAL_RUNNING" == 1 ]]; then
        stop_machine "$NORMAL_MACHINE" >/dev/null 2>&1 || true
    fi
    if [[ -n "$SOCAT_PID" ]]; then
        kill "$SOCAT_PID" >/dev/null 2>&1 || true
        wait "$SOCAT_PID" >/dev/null 2>&1 || true
    fi

    if [[ "$SUCCESS" == 1 && "$KEEP_STATE" != 1 ]]; then
        if [[ "$EMBEDDED_CREATED" == 1 ]]; then
            delete_machine "$EMBEDDED_MACHINE"
        fi
        if [[ "$NORMAL_CREATED" == 1 ]]; then
            delete_machine "$NORMAL_MACHINE"
        fi
        rm -f -- "$STATE_DIR/verify-h-${SOCKET_ID}.sock"
        rm -f -- "$STATE_DIR/verify-d-${SOCKET_ID}.sock"
        rm -f -- "$STATE_DIR/verify-v-${SOCKET_ID}.sock"
        rm -f -- "$STATE_DIR/verify-ed-${SOCKET_ID}.sock"
        rm -f -- "$STATE_DIR/verify-ev-${SOCKET_ID}.sock"
        rm -f -- "$STATE_DIR/verify-pack-${SOCKET_ID}.bin"
        rm -f -- "$STATE_DIR/verify-pack-${SOCKET_ID}.bin.smolmachine"
        rm -f -- "$STATE_DIR/verify-embedded-start-${SOCKET_ID}.log"
        rm -rf -- "$STATE_DIR/verify-pack-${SOCKET_ID}.staging"
    fi

    if [[ "$SUCCESS" != 1 ]]; then
        printf '\nVerification failed. State was preserved under %s\n' "$STATE_DIR" >&2
    elif [[ "$KEEP_STATE" == 1 ]]; then
        printf 'Verification state retained under %s\n' "$STATE_DIR"
    elif [[ "$EXPORT_PACK" == 1 ]]; then
        printf 'Verified pack retained at %s\n' "$EXPORTED_PACK"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

wait_for_guest_docker() {
    local machine="$1"
    local attempt
    for attempt in $(seq 1 90); do
        if "$SMOLVM_BIN" machine exec --name "$machine" -- \
            docker info --format '{{.Driver}} {{.ServerVersion}}' >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    fail "Docker did not become ready in machine $machine"
}

wait_for_host_docker() {
    local socket_path="$1"
    local attempt
    for attempt in $(seq 1 30); do
        if DOCKER_HOST="unix://$socket_path" docker info >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    fail "host Docker client could not reach $socket_path"
}

wait_for_http() {
    local port="$1"
    local attempt
    for attempt in $(seq 1 90); do
        if curl --fail --silent "http://127.0.0.1:$port" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    fail "Compose service did not recover on host port $port"
}

assert_output() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    if [[ "$actual" != "$expected" ]]; then
        fail "$label: expected '$expected', received '$actual'"
    fi
    printf '  ok: %s -> %s\n' "$label" "$actual"
}

verify_paths() {
    local docker_socket="$1"
    local vm_socket="$2"
    local port="$3"
    local port_result
    local host_to_vm_result
    local vm_to_host_result

    port_result="$(curl --fail --silent --show-error "http://127.0.0.1:$port")"
    host_to_vm_result="$(compose_for "$docker_socket" exec -T app python -c \
        'import socket; s=socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect("/run/smol-compose-evaluation/host.sock"); s.sendall(b"probe\n"); s.shutdown(socket.SHUT_WR); print(s.recv(4096).decode().strip())')"
    vm_to_host_result="$(python3 "$SCRIPT_DIR/fixtures/socket_probe.py" "$vm_socket" vm-to-host-ok)"

    assert_output port-exposure-ok "$port_result" "host TCP -> Compose"
    assert_output host-to-vm-ok "$host_to_vm_result" "Compose -> host Unix socket"
    assert_output vm-to-host-ok "$vm_to_host_result" "host -> Compose Unix socket"
}

mkdir -p "$STATE_DIR"

require_command docker
require_command socat
require_command curl
require_command python3
require_command seq

if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
elif docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
else
    fail "docker-compose or the Docker Compose plugin is required"
fi

[[ -x "$SMOLVM_BIN" ]] || fail "smolvm binary not found: $SMOLVM_BIN"

# A project-local state root is intentionally used. Fail before boot with a
# useful explanation if this checkout is so deeply nested that macOS cannot
# represent libkrun's per-VM Unix control socket.
CONTROL_PROBE="$STATE_DIR/0000000000000000/control.sock"
if (( ${#CONTROL_PROBE} >= 104 )); then
    fail "SMOLVM_DATA_DIR is too long for a macOS Unix socket (${#CONTROL_PROBE} bytes): $CONTROL_PROBE"
fi
for socket_path in \
    "$HOST_SOCKET" \
    "$DOCKER_SOCKET" \
    "$VM_SOCKET" \
    "$EMBEDDED_DOCKER_SOCKET" \
    "$EMBEDDED_VM_SOCKET"; do
    if (( ${#socket_path} >= 104 )); then
        fail "verification socket path is too long (${#socket_path} bytes): $socket_path"
    fi
done

export SMOLVM_DATA_DIR="$STATE_DIR"
if [[ -z "${SMOLVM_AGENT_ROOTFS:-}" && -d "$REPO_ROOT/target/agent-rootfs" ]]; then
    export SMOLVM_AGENT_ROOTFS="$REPO_ROOT/target/agent-rootfs"
fi
if [[ -z "${SMOLVM_LIB_DIR:-}" && -d "$STATE_DIR/build-lib" ]]; then
    export SMOLVM_LIB_DIR="$STATE_DIR/build-lib"
fi
if [[ -z "${LIBKRUN_BUNDLE:-}" && -d "$STATE_DIR/build-lib" ]]; then
    export LIBKRUN_BUNDLE="$STATE_DIR/build-lib"
fi

rm -f -- "$STATE_DIR/verify-h-${SOCKET_ID}.sock"
rm -f -- "$STATE_DIR/verify-d-${SOCKET_ID}.sock"
rm -f -- "$STATE_DIR/verify-v-${SOCKET_ID}.sock"
rm -f -- "$STATE_DIR/verify-ed-${SOCKET_ID}.sock"
rm -f -- "$STATE_DIR/verify-ev-${SOCKET_ID}.sock"
socat "UNIX-LISTEN:$HOST_SOCKET,unlink-early,fork" \
    'SYSTEM:printf "host-to-vm-ok\n"' >/dev/null 2>&1 &
SOCAT_PID=$!
for _attempt in $(seq 1 20); do
    [[ -S "$HOST_SOCKET" ]] && break
    sleep 0.1
done
[[ -S "$HOST_SOCKET" ]] || fail "host socket fixture did not start: $HOST_SOCKET"

printf '1/5 Creating normal Compose machine %s\n' "$NORMAL_MACHINE"
"$SMOLVM_BIN" machine create \
    --name "$NORMAL_MACHINE" \
    --smolfile "$SMOLFILE" \
    --net-backend virtio-net \
    --port "$NORMAL_PORT:8080" \
    --expose-socket "/var/run/docker.sock:$DOCKER_SOCKET" \
    --mount-socket "$HOST_SOCKET:/run/smol-compose-evaluation/host.sock" \
    --expose-socket "/run/smol-compose-evaluation/guest.sock:$VM_SOCKET"
NORMAL_CREATED=1

"$SMOLVM_BIN" machine start --name "$NORMAL_MACHINE"
NORMAL_RUNNING=1
wait_for_guest_docker "$NORMAL_MACHINE"
wait_for_host_docker "$DOCKER_SOCKET"
compose_for "$DOCKER_SOCKET" up -d --wait
NORMAL_COMPOSE=1
verify_paths "$DOCKER_SOCKET" "$VM_SOCKET" "$NORMAL_PORT"

printf '2/5 Restarting normal machine and rechecking persistence\n'
stop_machine "$NORMAL_MACHINE"
NORMAL_RUNNING=0
"$SMOLVM_BIN" machine start --name "$NORMAL_MACHINE"
NORMAL_RUNNING=1
wait_for_guest_docker "$NORMAL_MACHINE"
wait_for_host_docker "$DOCKER_SOCKET"
wait_for_http "$NORMAL_PORT"
verify_paths "$DOCKER_SOCKET" "$VM_SOCKET" "$NORMAL_PORT"
stop_machine "$NORMAL_MACHINE"
NORMAL_RUNNING=0

printf '3/5 Building embedded Docker runtime\n'
"$SMOLVM_BIN" pack create \
    --smolfile "$SMOLFILE" \
    --output "$PACK_OUTPUT" \
    --staging-dir "$PACK_STAGING"
[[ -x "$PACK_OUTPUT" ]] || fail "packed launcher was not created"
[[ -f "$PACK_OUTPUT.smolmachine" ]] || fail "packed .smolmachine was not created"

printf '4/5 Starting fresh machine from embedded artifact\n'
"$SMOLVM_BIN" machine create \
    --name "$EMBEDDED_MACHINE" \
    --from "$PACK_OUTPUT.smolmachine" \
    --net-backend virtio-net \
    --port "$EMBEDDED_PORT:8080" \
    --expose-socket "/var/run/docker.sock:$EMBEDDED_DOCKER_SOCKET" \
    --mount-socket "$HOST_SOCKET:/run/smol-compose-evaluation/host.sock" \
    --expose-socket "/run/smol-compose-evaluation/guest.sock:$EMBEDDED_VM_SOCKET"
EMBEDDED_CREATED=1

"$SMOLVM_BIN" machine start --name "$EMBEDDED_MACHINE" 2>&1 | tee "$EMBEDDED_START_LOG"
if grep -Fq 'Pulling docker:28-dind' "$EMBEDDED_START_LOG"; then
    fail "artifact-backed machine unexpectedly pulled docker:28-dind"
fi
EMBEDDED_RUNNING=1
wait_for_guest_docker "$EMBEDDED_MACHINE"
wait_for_host_docker "$EMBEDDED_DOCKER_SOCKET"
compose_for "$EMBEDDED_DOCKER_SOCKET" up -d --wait
EMBEDDED_COMPOSE=1

printf '5/5 Verifying embedded Compose paths\n'
verify_paths "$EMBEDDED_DOCKER_SOCKET" "$EMBEDDED_VM_SOCKET" "$EMBEDDED_PORT"

if [[ "$EXPORT_PACK" == 1 ]]; then
    cp -- "$PACK_OUTPUT.smolmachine" "$EXPORTED_PACK"
fi

SUCCESS=1
printf '\nDocker Compose verification passed.\n'
