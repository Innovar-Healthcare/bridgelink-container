#!/usr/bin/env bash
# Build the local JDK-21 / Derby-10.17 BridgeLink 26.9.0 test image.
#
# Prereqs:
#   - An existing innovarhealthcare/bridgelink:26.9.0-local image (the base app layout).
#   - A BridgeLink-internal checkout carrying the Derby 10.17.1.0 jars under
#     server/lib/database/ (set CONNECT_DIR to point at it).
#
# Usage:
#   CONNECT_DIR=../../../connect ./build.sh           # build, keep tag bl-2690-jdk21:test
#   CONNECT_DIR=../../../connect ./build.sh --overwrite-local   # also retag as 26.9.0-local
#
# This is a TEST image, not a release build. See Dockerfile header.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONNECT_DIR="${CONNECT_DIR:-$HERE/../../../connect}"
DERBY_SRC="$CONNECT_DIR/server/lib/database"
TAG="bl-2690-jdk21:test"

for j in derby-10.17.1.0.jar derbyshared-10.17.1.0.jar derbytools-10.17.1.0.jar; do
  if [[ ! -f "$DERBY_SRC/$j" ]]; then
    echo "ERROR: $j not found under $DERBY_SRC" >&2
    echo "Set CONNECT_DIR to a BridgeLink-internal checkout that has the Derby 10.17 jars." >&2
    exit 1
  fi
  cp "$DERBY_SRC/$j" "$HERE/$j"
done

# Match the base image's architecture (the base is single-arch).
ARCH=$(docker image inspect innovarhealthcare/bridgelink:26.9.0-local --format '{{.Architecture}}')
echo "Building $TAG for linux/$ARCH ..."
docker build --platform "linux/$ARCH" -t "$TAG" "$HERE"

# Do not leave the copied jars in the working tree (they live in connect, not here).
rm -f "$HERE"/derby-10.17.1.0.jar "$HERE"/derbyshared-10.17.1.0.jar "$HERE"/derbytools-10.17.1.0.jar

if [[ "${1:-}" == "--overwrite-local" ]]; then
  docker tag "$TAG" innovarhealthcare/bridgelink:26.9.0-local
  echo "Retagged as innovarhealthcare/bridgelink:26.9.0-local (run-migration-test.sh --local will use it)."
fi

echo "Done. Boot-check: docker run --rm -d -p 18443:8443 -e MP_KEYSTORE_KEYPASS=bridgelinkKeystore -e MP_KEYSTORE_STOREPASS=bridgelinkKeypass $TAG"
