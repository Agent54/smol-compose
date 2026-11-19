#!/usr/bin/env bash
set -euo pipefail
repository="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repository/examples/docker-compose/.state"
fixture="$(mktemp -d "$repository/examples/docker-compose/.state/input-tests.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/builder" "$fixture/bin" "$fixture/.state/builder-assets"
cp "$repository/examples/docker-compose/prepare-runtime.sh" "$fixture/"
cp "$repository/examples/docker-compose/builder/"* "$fixture/builder/"
printf buildx > "$fixture/.state/builder-assets/buildx-vtest"
buildx_checksum="$(shasum -a 256 "$fixture/.state/builder-assets/buildx-vtest" | awk '{print $1}')"
first_digest="$(printf first | shasum -a 256 | awk '{print $1}')"
second_digest="$(printf second | shasum -a 256 | awk '{print $1}')"
printf 'image = "docker:test@sha256:%s"\n' "$first_digest" > "$fixture/docker-compose.smolfile"
write_lock() {
    printf 'DOCKER_VERSION=test\nBUILDX_VERSION=test\nBUILDX_LINUX_ARM64_SHA256=%s\nBUILDKIT_VERSION=test\nBUILDKIT_IMAGE=moby/buildkit@sha256:%s\n' \
        "$buildx_checksum" "$1" > "$fixture/builder/ContainerTools.lock"
}
cat > "$fixture/bin/crane" <<'SH'
#!/bin/bash
set -eu
if [[ "$1" == pull ]]; then
    printf '%s\n' "$6" >> "$INPUT_TEST_PULLS"
    printf '%s\n' "$6" > "$7"
else
    test -s "$3"
fi
SH
cat > "$fixture/bin/smolvm" <<'SH'
#!/bin/bash
set -eu
printf '%s\n' "$*" >> "$INPUT_TEST_COMMANDS"
if [[ "$1 $2" == 'pack create' ]]; then
    while [[ "$1" != --output ]]; do shift; done
    printf artifact > "$2.smolmachine"
fi
SH
chmod +x "$fixture/bin/"*
export SMOLVM="$fixture/bin/smolvm" CRANE="$fixture/bin/crane"
export INPUT_TEST_PULLS="$fixture/pulls" INPUT_TEST_COMMANDS="$fixture/commands"
unset SMOLVM_BUILD_BASE_ARTIFACT
write_lock "$first_digest"
bash "$fixture/prepare-runtime.sh" "$fixture/first"
bash "$fixture/prepare-runtime.sh" "$fixture/repeated"
test "$(wc -l < "$fixture/pulls" | tr -d ' ')" = 1
write_lock "$second_digest"
bash "$fixture/prepare-runtime.sh" "$fixture/changed"
test "$(wc -l < "$fixture/pulls" | tr -d ' ')" = 2
grep -Fxq "moby/buildkit@sha256:$second_digest" "$fixture/pulls"
SMOLVM_BUILD_BASE_ARTIFACT="$fixture/first.smolmachine" bash "$fixture/prepare-runtime.sh" "$fixture/reused"
grep -Fq -- "--from $fixture/first.smolmachine" "$fixture/commands"
printf 'image = "docker:test@sha256:%s"\n' "$second_digest" > "$fixture/docker-compose.smolfile"
before="$(wc -l < "$fixture/commands")"
if SMOLVM_BUILD_BASE_ARTIFACT="$fixture/first.smolmachine" bash "$fixture/prepare-runtime.sh" "$fixture/rejected" > "$fixture/error" 2>&1; then
    echo 'Expected a changed Docker digest to reject the old base' >&2
    exit 1
fi
grep -Fq 'Build base does not match the pinned Docker image' "$fixture/error"
test "$(wc -l < "$fixture/commands")" = "$before"
printf 'PASS: digest-keyed archive cache and exact Docker base identity\n'
