#!/bin/sh
# Called only for an actual build, never by the VM entrypoint.
set -eu
tools=/usr/local/share/xe-builder
. "$tools/ContainerTools.lock"
export DOCKER_HOST=unix:///var/run/docker.sock
export DOCKER_CONFIG=/storage/xe-build-client
unset DOCKER_CONTEXT DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION BUILDX_BUILDER BUILDX_CONFIG
[ "${1:?Expected Docker version is required}" = "$DOCKER_VERSION" ]
[ "${2:?Expected BuildKit image is required}" = "$BUILDKIT_IMAGE_ID" ]
actual="$(/usr/local/bin/docker version --format '{{.Server.Version}}')"
[ "$actual" = "$DOCKER_VERSION" ] || { echo "Expected Docker $DOCKER_VERSION, got $actual" >&2; exit 1; }
umask 077
mkdir -p "$DOCKER_CONFIG"
# Serialize image import and builder registration across concurrent builds.
exec 9>"$DOCKER_CONFIG/prepare.lock"
flock -x 9
if ! /usr/local/bin/docker image inspect "$BUILDKIT_IMAGE_ID" >/dev/null 2>&1; then
    /usr/local/bin/docker load --input "$tools/buildkit.tar"
fi
/usr/local/bin/docker image inspect "$BUILDKIT_IMAGE_ID" >/dev/null
set --
if [ -f "$DOCKER_CONFIG/buildx/instances/xe" ]; then set -- --append; fi
/usr/local/libexec/docker/cli-plugins/docker-buildx create --name xe --node xe0 "$@" \
    --driver docker-container --driver-opt "image=$BUILDKIT_IMAGE_ID" \
    --driver-opt restart-policy=no --driver-opt default-load=true \
    --buildkitd-config "$tools/buildkitd.toml" "$DOCKER_HOST"
# This script is reached only from a build request. Bootstrap under the lock so
# simultaneous first builds cannot race to create the same builder container.
/usr/local/libexec/docker/cli-plugins/docker-buildx inspect xe --bootstrap
version="$(/usr/local/bin/docker exec buildx_buildkit_xe0 buildkitd --version)"
case "$version" in *"v$BUILDKIT_VERSION "*) ;; *) echo "Unexpected BuildKit: $version" >&2; exit 1 ;; esac
