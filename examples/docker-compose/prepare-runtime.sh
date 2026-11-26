#!/usr/bin/env bash
# Assemble guest tools into the VM filesystem before packing the runtime.
# No Docker daemon, BuildKit image import, or builder is needed on the host.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd -P)"
source "$script_dir/builder/ContainerTools.lock"
smolvm="${SMOLVM:?Set SMOLVM to the runtime executable}"
crane="${CRANE:-crane}"
output="${1:?usage: prepare-runtime.sh OUTPUT_EXECUTABLE}"
state="$script_dir/state/builder-assets"
buildkit_archive="$state/buildkit-${BUILDKIT_IMAGE##*@}.tar"
mkdir -p "$state" "$(dirname "$output")"
case "$(uname -m)" in arm64|aarch64) ;; *) echo 'This image definition targets ARM64' >&2; exit 1 ;; esac
if [[ ! -f "$state/buildx-v$BUILDX_VERSION" ]]; then
    curl --fail --location "https://github.com/docker/buildx/releases/download/v$BUILDX_VERSION/buildx-v$BUILDX_VERSION.linux-arm64" \
        --output "$state/buildx-v$BUILDX_VERSION.download"
    [[ "$(shasum -a 256 "$state/buildx-v$BUILDX_VERSION.download" | awk '{print $1}')" = "$BUILDX_LINUX_ARM64_SHA256" ]]
    mv "$state/buildx-v$BUILDX_VERSION.download" "$state/buildx-v$BUILDX_VERSION"
fi
[[ "$(shasum -a 256 "$state/buildx-v$BUILDX_VERSION" | awk '{print $1}')" = "$BUILDX_LINUX_ARM64_SHA256" ]]
if [[ ! -f "$buildkit_archive" ]]; then
    "$crane" pull --platform linux/arm64 --format tarball "$BUILDKIT_IMAGE" "$buildkit_archive.download"
    "$crane" validate --tarball "$buildkit_archive.download"
    mv "$buildkit_archive.download" "$buildkit_archive"
fi
"$crane" validate --tarball "$buildkit_archive"
cp "$script_dir/builder/ContainerTools.lock" "$script_dir/builder/prepare-builder.sh" \
    "$script_dir/builder/cache.sh" "$script_dir/builder/buildkitd.toml" "$script_dir/builder/daemon.json" "$state/"
# An explicit pristine build artifact avoids downloading its base layers again.
# The assembly below reapplies the current recipe; this never upgrades a user's VM.
base_image="$(sed -n 's/^image = "\(.*\)"/\1/p' "$script_dir/docker-compose.smolfile")"
[[ -n "$base_image" ]]
# Assembly uses only a shell; Docker must not create runtime state in the image.
source_args=(--image "$base_image" --net --cpus 2 --mem 2048)
if [[ -n "${SMOLVM_BUILD_BASE_ARTIFACT:-}" ]]; then
    base="$SMOLVM_BUILD_BASE_ARTIFACT"
    expected="$(sed -n 's/^SMOLVM_COMPOSE_SHA256=//p' "$base.builder.lock")"
    [[ "$expected" =~ ^[0-9a-f]{64}$ && "$(shasum -a 256 "$base" | awk '{print $1}')" = "$expected" ]]
    [[ "$(sed -n 's/^DOCKER_VERSION=//p' "$base.builder.lock")" = "$DOCKER_VERSION" ]]
    [[ "$(sed -n 's/^DOCKER_IMAGE=//p' "$base.builder.lock")" = "$base_image" ]] || {
        echo 'Build base does not match the pinned Docker image; rebuild without SMOLVM_BUILD_BASE_ARTIFACT.' >&2
        exit 1
    }
    source_args=(--from "$base")
fi
machine="compose-image-build-$$"
created=0
cleanup() {
    if [[ "$created" = 1 ]]; then "$smolvm" machine stop --name "$machine"; fi
}
trap cleanup EXIT
"$smolvm" machine create --name "$machine" "${source_args[@]}" \
    --net-backend virtio-net --volume "$state:/opt/image-build:ro" -- /bin/sh -c 'sleep 2147483647'
created=1
"$smolvm" machine start --name "$machine"
"$smolvm" machine exec --name "$machine" --timeout 180s -- /bin/sh -ec '
    . /opt/image-build/ContainerTools.lock
    test "$(/usr/local/bin/docker --version | cut -d " " -f 3 | tr -d ,)" = "$DOCKER_VERSION"
    command -v flock
    mkdir -p /usr/local/share/xe-builder /usr/local/libexec/docker/cli-plugins /etc/docker
    cp /opt/image-build/daemon.json /etc/docker/daemon.json
    cp /opt/image-build/ContainerTools.lock /opt/image-build/prepare-builder.sh /opt/image-build/cache.sh /opt/image-build/buildkitd.toml /usr/local/share/xe-builder/
    cp "/opt/image-build/buildkit-${BUILDKIT_IMAGE##*@}.tar" /usr/local/share/xe-builder/buildkit.tar
    cp "/opt/image-build/buildx-v$BUILDX_VERSION" /usr/local/libexec/docker/cli-plugins/docker-buildx
    chmod 755 /usr/local/share/xe-builder/*.sh /usr/local/libexec/docker/cli-plugins/docker-buildx
    /usr/local/libexec/docker/cli-plugins/docker-buildx version
'
"$smolvm" machine stop --name "$machine"
created=0
"$smolvm" pack create --from-vm "$machine" --smolfile "$script_dir/docker-compose.smolfile" \
    --output "$output" --staging-dir "$state/pack"
{
    cat "$state/ContainerTools.lock"
    printf 'DOCKER_IMAGE=%s\n' "$base_image"
    printf 'SMOLVM_RUNTIME_FORMAT=containerd-buildkit-2\n'
    printf 'SMOLVM_COMPOSE_SHA256=%s\n' "$(shasum -a 256 "$output.smolmachine" | awk '{print $1}')"
    printf 'SMOLVM_COMPOSE_SOURCE_REVISION=%s\n' "$(git -C "$script_dir" describe --always --dirty)"
} > "$output.smolmachine.builder.lock"
# Keep failed preparation state for diagnosis; remove only this successful build VM.
"$smolvm" machine delete --name "$machine" --force
echo "Packed Docker $DOCKER_VERSION and BuildKit $BUILDKIT_VERSION into $output.smolmachine"
