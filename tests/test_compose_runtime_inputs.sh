#!/usr/bin/env bash
set -euo pipefail
repository="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repository/examples/docker-compose/state"
fixture_parent="$(mktemp -d "$repository/examples/docker-compose/state/input-tests.XXXXXX")"
readonly fixture_parent
fixture="$fixture_parent/runtime-inputs.fixture"
readonly fixture
trap 'rm -rf -- "${fixture_parent:?}/runtime-inputs.fixture"; rmdir -- "${fixture_parent:?}"' EXIT
mkdir -p "$fixture/builder" "$fixture/bin" "$fixture/state/builder-assets"
cp "$repository/examples/docker-compose/prepare-runtime.sh" "$fixture/"
cp "$repository/examples/docker-compose/builder/"* "$fixture/builder/"
printf buildx > "$fixture/state/builder-assets/buildx-vtest"
buildx_checksum="$(shasum -a 256 "$fixture/state/builder-assets/buildx-vtest" | awk '{print $1}')"
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

# Exercise the guest preparation script with both forms of Docker load output.
# Substitute only its fixed guest paths so the test stays inside its fixture.
# Each -e adds a rule. s|guest path|fixture path|g replaces every occurrence.
# The four rules redirect tool configuration, Docker, Buildx, and client state.
# Leave BUILDER_TEST_ROOT literal here so the copied shell script expands it
# with quotes, including when the checkout path contains spaces or & or |.
export BUILDER_TEST_ROOT="$fixture"
sed -e 's|/usr/local/share/xe-builder|"${BUILDER_TEST_ROOT}/builder"|g' \
    -e 's|/usr/local/bin/docker|"${BUILDER_TEST_ROOT}/bin/docker"|g' \
    -e 's|/usr/local/libexec/docker/cli-plugins/docker-buildx|"${BUILDER_TEST_ROOT}/bin/docker-buildx"|g' \
    -e 's|/storage/xe-build-client|"${BUILDER_TEST_ROOT}/client"|g' \
    "$repository/examples/docker-compose/builder/prepare-builder.sh" > "$fixture/prepare-builder.sh"
cat > "$fixture/bin/docker" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$BUILDER_TEST_COMMANDS"
case "$1 $2" in
    'version --format') printf 'test\n' ;;
    'load --input') printf '%s\n' "$BUILDER_TEST_LOAD_OUTPUT" ;;
    'image inspect')
        if [ "$3" = --format ]; then
            [ "$4" = '{{.Id}}' ]
            [ "$5" = "$BUILDER_TEST_LOADED_REF" ]
            [ "${BUILDER_TEST_INSPECT_FAIL:-0}" = 0 ]
            printf '%s\n' "$BUILDER_TEST_IMAGE_ID"
        else
            [ "$3" = "$BUILDER_TEST_IMAGE_ID" ]
        fi ;;
    'container ls') ;;
    'info --format') printf 'cgroupfs\n' ;;
    'container create') ;;
    'container inspect') printf '%s\n' "$BUILDER_TEST_IMAGE_ID" ;;
    'exec buildx_buildkit_xe0') printf 'buildkitd vtest commit\n' ;;
    *) exit 1 ;;
esac
SH
printf '#!/bin/sh\nexit 0\n' > "$fixture/bin/docker-buildx"
# Each invocation is sequential here; production serializes them with flock.
printf '#!/bin/sh\nexit 0\n' > "$fixture/bin/flock"
chmod +x "$fixture/bin/docker" "$fixture/bin/docker-buildx" "$fixture/bin/flock"
export PATH="$fixture/bin:$PATH"
export BUILDER_TEST_COMMANDS="$fixture/builder-commands"
export BUILDER_TEST_IMAGE_ID="sha256:$first_digest"
identity="$fixture/client/buildkit-sha256:$second_digest.id"
for loaded_ref in "$BUILDER_TEST_IMAGE_ID" moby/buildkit:i-was-a-digest; do
    export BUILDER_TEST_LOADED_REF="$loaded_ref"
    if [[ "$loaded_ref" = sha256:* ]]; then
        export BUILDER_TEST_LOAD_OUTPUT="Loaded image ID: $loaded_ref"
    else
        export BUILDER_TEST_LOAD_OUTPUT="Loaded image: $loaded_ref"
    fi
    rm -f -- "${fixture:?}/client/buildkit-sha256:${second_digest:?}.id"
    result="$(sh "$fixture/prepare-builder.sh" test "moby/buildkit@sha256:$second_digest")"
    test "$result" = "$BUILDER_TEST_IMAGE_ID"
    test "$(cat "$identity")" = "$BUILDER_TEST_IMAGE_ID"
done
grep -Fq -- "--pull=never --name buildx_buildkit_xe0" "$BUILDER_TEST_COMMANDS"
grep -Fq -- "$BUILDER_TEST_IMAGE_ID --config" "$BUILDER_TEST_COMMANDS"
loads="$(grep -c '^load --input' "$BUILDER_TEST_COMMANDS")"
sh "$fixture/prepare-builder.sh" test "moby/buildkit@sha256:$second_digest" >/dev/null
test "$(grep -c '^load --input' "$BUILDER_TEST_COMMANDS")" = "$loads"
for failure in empty multiple inspect; do
    rm -f -- "${fixture:?}/client/buildkit-sha256:${second_digest:?}.id"
    export BUILDER_TEST_INSPECT_FAIL=0
    case "$failure" in
        empty) export BUILDER_TEST_LOAD_OUTPUT='No loaded image' ;;
        multiple) export BUILDER_TEST_LOAD_OUTPUT=$'Loaded image: first\nLoaded image: second' ;;
        inspect)
            export BUILDER_TEST_LOAD_OUTPUT="Loaded image: $BUILDER_TEST_LOADED_REF"
            export BUILDER_TEST_INSPECT_FAIL=1 ;;
    esac
    if sh "$fixture/prepare-builder.sh" test "moby/buildkit@sha256:$second_digest" > "$fixture/error" 2>&1; then
        echo "Expected $failure to reject the loaded BuildKit identity" >&2
        exit 1
    fi
    test ! -e "$identity"
done
printf 'PASS: tagged and untagged BuildKit imports resolve to Docker image IDs\n'
