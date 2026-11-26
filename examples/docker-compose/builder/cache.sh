#!/bin/sh
set -eu
export DOCKER_HOST=unix:///var/run/docker.sock
export DOCKER_CONFIG=/storage/xe-build-client
unset DOCKER_CONTEXT DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION BUILDX_BUILDER BUILDX_CONFIG
# Maintenance must not wake a stopped builder or create one on a fresh VM.
running="$(/usr/local/bin/docker container ls --filter name=^/buildx_buildkit_xe0$ --format '{{.Names}}')"
[ "$running" = buildx_buildkit_xe0 ] || exit 0
exec /usr/local/libexec/docker/cli-plugins/docker-buildx "$@"
