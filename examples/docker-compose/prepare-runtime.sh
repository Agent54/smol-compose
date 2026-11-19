#!/usr/bin/env bash
# Assemble guest tools into the VM filesystem before packing the runtime.
# No Docker daemon, BuildKit image import, or builder is needed on the host.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd -P)"
source "$script_dir/builder/ContainerTools.lock"
smolvm="${SMOLVM:?Set SMOLVM to the runtime executable}"
crane="${CRANE:-crane}"
output="${1:?usage: prepare-runtime.sh OUTPUT_EXECUTABLE}"
state="$script_dir/.state/builder-assets"
mkdir -p "$state" "$(dirname "$output")"
case "$(uname -m)" in arm64|aarch64) ;; *) echo 'This image definition targets ARM64' >&2; exit 1 ;; esac
if [[ ! -f "$state/buildx-v$BUILDX_VERSION" ]]; then
    curl --fail --location "https://github.com/docker/buildx/releases/download/v$BUILDX_VERSION/buildx-v$BUILDX_VERSION.linux-arm64" \
        --output "$state/buildx-v$BUILDX_VERSION.download"
    [[ "$(shasum -a 256 "$state/buildx-v$BUILDX_VERSION.download" | awk '{print $1}')" = "$BUILDX_LINUX_ARM64_SHA256" ]]
    mv "$state/buildx-v$BUILDX_VERSION.download" "$state/buildx-v$BUILDX_VERSION"
fi
[[ "$(shasum -a 256 "$state/buildx-v$BUILDX_VERSION" | awk '{print $1}')" = "$BUILDX_LINUX_ARM64_SHA256" ]]
if [[ ! -f "$state/buildkit-v$BUILDKIT_VERSION.tar" ]]; then
    "$crane" pull --platform linux/arm64 --format tarball "$BUILDKIT_IMAGE" "$state/buildkit-v$BUILDKIT_VERSION.tar.download"
    python3 "$script_dir/builder/verify-archive.py" "$state/buildkit-v$BUILDKIT_VERSION.tar.download" "$BUILDKIT_IMAGE_ID"
    mv "$state/buildkit-v$BUILDKIT_VERSION.tar.download" "$state/buildkit-v$BUILDKIT_VERSION.tar"
fi
python3 "$script_dir/builder/verify-archive.py" "$state/buildkit-v$BUILDKIT_VERSION.tar" "$BUILDKIT_IMAGE_ID"
cp "$script_dir/builder/ContainerTools.lock" "$script_dir/builder/prepare-builder.sh" \
    "$script_dir/builder/cache.sh" "$script_dir/builder/buildkitd.toml" "$script_dir/builder/daemon.json" "$state/"
machine="compose-image-build-$$"
created=0
cleanup() {
    if [[ "$created" = 1 ]]; then "$smolvm" machine stop --name "$machine"; fi
}
trap cleanup EXIT
"$smolvm" machine create --name "$machine" --smolfile "$script_dir/docker-compose.smolfile" \
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
    cp "/opt/image-build/buildkit-v$BUILDKIT_VERSION.tar" /usr/local/share/xe-builder/buildkit.tar
    cp "/opt/image-build/buildx-v$BUILDX_VERSION" /usr/local/libexec/docker/cli-plugins/docker-buildx
    chmod 755 /usr/local/share/xe-builder/*.sh /usr/local/libexec/docker/cli-plugins/docker-buildx
    /usr/local/libexec/docker/cli-plugins/docker-buildx version
'
"$smolvm" machine stop --name "$machine"
created=0
"$smolvm" pack create --from-vm "$machine" --smolfile "$script_dir/docker-compose.smolfile" \
    --output "$output" --staging-dir "$state/pack"
{
    cat "$script_dir/builder/ContainerTools.lock"
    printf 'SMOLVM_RUNTIME_FORMAT=embedded-buildkit-1\n'
    printf 'SMOLVM_COMPOSE_SHA256=%s\n' "$(shasum -a 256 "$output.smolmachine" | awk '{print $1}')"
    printf 'SMOLVM_COMPOSE_SOURCE_REVISION=%s\n' "$(git -C "$script_dir" describe --always --dirty)"
} > "$output.smolmachine.builder.lock"
# Keep failed preparation state for diagnosis; remove only this successful build VM.
"$smolvm" machine delete --name "$machine" --force
echo "Packed Docker $DOCKER_VERSION and BuildKit $BUILDKIT_VERSION into $output.smolmachine"
