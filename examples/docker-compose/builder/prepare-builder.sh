#!/bin/sh
# Called only for an actual build, never by the VM entrypoint.
set -eu
tools=/usr/local/share/xe-builder
. "$tools/ContainerTools.lock"
export DOCKER_HOST=unix:///var/run/docker.sock
export DOCKER_CONFIG=/storage/xe-build-client
unset DOCKER_CONTEXT DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION BUILDX_BUILDER BUILDX_CONFIG
[ "${1:?Expected Docker version is required}" = "$DOCKER_VERSION" ]
[ "${2:?Expected BuildKit image is required}" = "$BUILDKIT_IMAGE" ]
actual="$(/usr/local/bin/docker version --format '{{.Server.Version}}')"
[ "$actual" = "$DOCKER_VERSION" ] || { echo "Expected Docker $DOCKER_VERSION, got $actual" >&2; exit 1; }
umask 077
mkdir -p "$DOCKER_CONFIG"
# Serialize image import and builder registration across concurrent builds.
exec 9>"$DOCKER_CONFIG/prepare.lock"
flock -x 9
identity="$DOCKER_CONFIG/buildkit-${BUILDKIT_IMAGE##*@}.id"
image_id=
if [ -f "$identity" ]; then image_id="$(cat "$identity")"; fi
if [ -z "$image_id" ] || ! /usr/local/bin/docker image inspect "$image_id" >/dev/null 2>&1; then
    # The pinned, single-image archive is untagged. Let Docker assign its ID;
    # never reconstruct the importer manifest or assume a particular store.
    loaded="$(/usr/local/bin/docker load --input "$tools/buildkit.tar")"
    printf '%s\n' "$loaded" >&2
    image_id="$(printf '%s\n' "$loaded" | sed -n 's/^Loaded image ID: //p')"
    [ -n "$image_id" ] || { echo 'Docker did not return the loaded BuildKit image ID' >&2; exit 1; }
    /usr/local/bin/docker image inspect "$image_id" >/dev/null
    printf '%s\n' "$image_id" > "$identity.tmp"
    mv "$identity.tmp" "$identity"
fi
builder=buildx_buildkit_xe0
# Buildx's docker-container driver always pulls when it creates a container,
# even for an already-loaded image ID. Create from the bundled image explicitly
# with pulls forbidden; Buildx then owns startup, readiness and build transport.
existing="$(/usr/local/bin/docker container ls --all --quiet --filter "name=^/$builder$")"
if [ -z "$existing" ]; then
    set --
    if [ "$(/usr/local/bin/docker info --format '{{.CgroupDriver}}')" = cgroupfs ]; then
        set -- --cgroup-parent /docker/buildx
    fi
    /usr/local/bin/docker container create --pull=never --name "$builder" \
        --privileged --init --restart=no "$@" \
        --mount "type=volume,source=${builder}_state,target=/var/lib/buildkit" \
        --mount "type=bind,source=$tools/buildkitd.toml,target=/etc/buildkit/buildkitd.toml,readonly" \
        "$image_id" --config /etc/buildkit/buildkitd.toml --allow-insecure-entitlement network.host >&2
fi
[ "$(/usr/local/bin/docker container inspect --format '{{.Image}}' "$builder")" = "$image_id" ] || {
    echo 'The existing BuildKit container does not use the bundled image' >&2; exit 1;
}
set --
if [ -f "$DOCKER_CONFIG/buildx/instances/xe" ]; then set -- --append; fi
/usr/local/libexec/docker/cli-plugins/docker-buildx create --name xe --node xe0 "$@" \
    --driver docker-container --driver-opt "image=$image_id" \
    --driver-opt restart-policy=no --driver-opt default-load=true \
    --buildkitd-config "$tools/buildkitd.toml" "$DOCKER_HOST" >&2
# This script is reached only from a build request. Bootstrap under the lock so
# simultaneous first builds cannot race to create the same builder container.
/usr/local/libexec/docker/cli-plugins/docker-buildx inspect xe --bootstrap >&2
version="$(/usr/local/bin/docker exec buildx_buildkit_xe0 buildkitd --version)"
case "$version" in *"v$BUILDKIT_VERSION "*) ;; *) echo "Unexpected BuildKit: $version" >&2; exit 1 ;; esac
# Stdout is the opaque Docker ID consumed by the host Buildx wrapper.
printf '%s\n' "$image_id"
