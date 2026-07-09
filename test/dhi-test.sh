#!/usr/bin/env bash
#
# Automated acceptance tests for the hardened (DHI) BridgeLink image (Dockerfile.dhi) — IRT-1356.
# Asserts the properties Sectra care about plus config-injection parity with the Rocky image.
#
# Usage:
#   BINARY_URL="https://.../BridgeLink_unix_26_3_1.tar.gz" test/dhi-test.sh   # builds, then tests
#   IMAGE=innovarhealthcare/bridgelink:26.3.1-dhi SKIP_BUILD=1 test/dhi-test.sh   # tests existing image
#
# Requires: docker (with buildx), python3, curl. For the build/DHI-base pull: `docker login dhi.io`.
set -u

IMAGE="${IMAGE:-innovarhealthcare/bridgelink:dhi-test}"
SKIP_BUILD="${SKIP_BUILD:-0}"
NET="bl-dhi-test-net-$$"
WORK="$(mktemp -d)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PASS=0 FAIL=0

# ---- helpers ----------------------------------------------------------------------------------
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
info() { echo "== $1"; }

cleanup() {
  docker rm -f "${CIDS[@]}" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
CIDS=()
trap cleanup EXIT
run() { local name="$1"; shift; CIDS+=("$name"); docker run -d --name "$name" "$@" "$IMAGE" >/dev/null; }

# Poll a container's logs for a pattern (default: successful start). Returns non-zero on timeout.
wait_for_log() {
  local name="$1" pattern="${2:-server successfully started}" timeout="${3:-90}" i=0
  while [ "$i" -lt "$timeout" ]; do
    docker logs "$name" 2>&1 | grep -qE "$pattern" && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}

# Discover the ephemeral host port docker assigned to container port 8443.
https_port() { docker port "$1" 8443/tcp | head -1 | sed 's/.*://'; }

api_code() {
  curl -k -s -o /dev/null -w '%{http_code}' \
       -H 'X-Requested-With: XMLHttpRequest' "https://localhost:$1/api/server/version"
}

# ---- fixtures ---------------------------------------------------------------------------------
mkdir -p "$WORK/secrets" "$WORK/ext" "$WORK/httproot"
printf 'secret.injected.prop = fromSecret\ndatabase.max-connections = 42\n' > "$WORK/secrets/mirth_properties"
printf -- '-Dsecret.vmopt=enabled\n' > "$WORK/secrets/blserver_vmoptions"
python3 - "$WORK" <<'PY'
import os, sys, zipfile
w = sys.argv[1]
d = os.path.join(w, "myextension"); os.makedirs(d, exist_ok=True)
open(os.path.join(d, "plugin.txt"), "w").write("hello from custom extension\n")
for dest in (os.path.join(w, "ext", "myextension.zip"), os.path.join(w, "httproot", "myextension.zip")):
    with zipfile.ZipFile(dest, "w") as z:
        z.write(os.path.join(d, "plugin.txt"), "myextension/plugin.txt")
PY

# ---- build (optional) -------------------------------------------------------------------------
if [ "$SKIP_BUILD" != "1" ]; then
  info "Building $IMAGE from Dockerfile.dhi"
  : "${BINARY_URL:?set BINARY_URL to build, or set SKIP_BUILD=1 to test an existing IMAGE}"
  docker build -f "$REPO_ROOT/Dockerfile.dhi" --load \
    --build-arg BINARY_URL="$BINARY_URL" \
    ${AWS_CREDENTIALS_FILE:+--secret id=aws_credentials,src=$AWS_CREDENTIALS_FILE} \
    -t "$IMAGE" "$REPO_ROOT" || { echo "BUILD FAILED"; exit 1; }
fi

docker network create "$NET" >/dev/null

# ---- 1. Hardening: no shell / no bash in the runtime -----------------------------------------
info "1. Hardened runtime has no shell"
if docker run --rm --entrypoint sh "$IMAGE" -c 'echo x' >/dev/null 2>&1; then bad "sh present"; else ok "no sh"; fi
if docker run --rm --entrypoint /bin/bash "$IMAGE" -c 'echo x' >/dev/null 2>&1; then bad "bash present"; else ok "no bash"; fi

# ---- 2. Runs non-root as UID 65532 ------------------------------------------------------------
info "2. Non-root UID 65532"
U="$(docker image inspect "$IMAGE" --format '{{.Config.User}}')"
[ "$U" = "65532" ] && ok "image User=65532" || bad "image User=$U (expected 65532)"

# ---- 3. Boot (Derby) + config injection -------------------------------------------------------
info "3. Boot on Derby + MP_/SERVER_ID/MP_VMOPTIONS injection"
run bl-derby -p 8443 \
  -e SERVER_ID=11111111-2222-3333-4444-555555555555 \
  -e MP_KEYSTORE_STOREPASS=testStorePass123 \
  -e "MP_VMOPTIONS=512,-Dfoo.bar=baz"
if wait_for_log bl-derby; then
  ok "server started"
  P="$(https_port bl-derby)"
  [ "$(api_code "$P")" = "200" ] && ok "API 200" || bad "API not 200"
  docker cp bl-derby:/opt/bridgelink/appdata/server.id "$WORK/sid" >/dev/null 2>&1
  grep -q '11111111-2222-3333-4444-555555555555' "$WORK/sid" && ok "SERVER_ID written" || bad "SERVER_ID missing"
  docker cp bl-derby:/opt/bridgelink/conf/mirth.properties "$WORK/mp" >/dev/null 2>&1
  grep -q '^keystore.storepass = testStorePass123' "$WORK/mp" && ok "MP_ injected" || bad "MP_ not injected"
  docker logs bl-derby 2>&1 | grep -q -- '-Xmx512m' && ok "MP_VMOPTIONS -Xmx applied" || bad "MP_VMOPTIONS not applied"
  # add-opens must appear exactly once (dedup)
  N="$(docker logs bl-derby 2>&1 | grep -o 'add-opens=java.base/java.util=ALL-UNNAMED' | wc -l | tr -d ' ')"
  [ "$N" = "1" ] && ok "add-opens dedup (x1)" || bad "add-opens appears x$N"
else
  bad "server did not start (Derby)"; docker logs bl-derby 2>&1 | tail -20
fi

# ---- 4. Docker secrets + custom-extensions zip ------------------------------------------------
info "4. Docker secrets + custom-extensions volume"
run bl-secrets -p 8443 \
  -v "$WORK/secrets/mirth_properties:/run/secrets/mirth_properties:ro" \
  -v "$WORK/secrets/blserver_vmoptions:/run/secrets/blserver_vmoptions:ro" \
  -v "$WORK/ext:/opt/bridgelink/custom-extensions:ro"
if wait_for_log bl-secrets; then
  docker cp bl-secrets:/opt/bridgelink/conf/mirth.properties "$WORK/mp2" >/dev/null 2>&1
  grep -q '^secret.injected.prop = fromSecret' "$WORK/mp2" && ok "properties secret merged" || bad "properties secret not merged"
  docker logs bl-secrets 2>&1 | grep -q -- '-Dsecret.vmopt=enabled' && ok "vmoptions secret appended" || bad "vmoptions secret missing"
  docker cp bl-secrets:/opt/bridgelink/extensions/myextension/plugin.txt "$WORK/pl" >/dev/null 2>&1 \
    && ok "custom-extension zip extracted" || bad "custom-extension not extracted"
else
  bad "server did not start (secrets)"
fi

# ---- 5. HTTP download path (EXTENSIONS_DOWNLOAD via HttpClient) --------------------------------
info "5. HTTP download (EXTENSIONS_DOWNLOAD)"
docker run -d --name fileserver --network "$NET" \
  -v "$WORK/httproot:/usr/share/nginx/html:ro" nginx:alpine >/dev/null && CIDS+=(fileserver)
run bl-dl --network "$NET" -e EXTENSIONS_DOWNLOAD="http://fileserver/myextension.zip"
if wait_for_log bl-dl; then
  docker cp bl-dl:/opt/bridgelink/extensions/myextension/plugin.txt "$WORK/pl2" >/dev/null 2>&1 \
    && ok "downloaded + extracted via HttpClient" || bad "HTTP download/extract failed"
else
  bad "server did not start (download)"
fi

# ---- 6. Postgres backend ----------------------------------------------------------------------
info "6. Postgres backend"
docker run -d --name pg --network "$NET" \
  -e POSTGRES_USER=bridgelinktest -e POSTGRES_PASSWORD=bridgelinktest -e POSTGRES_DB=bridgelinkdb \
  postgres:16-alpine >/dev/null && CIDS+=(pg)
run bl-pg --network "$NET" -p 8443 \
  -e MP_DATABASE=postgres \
  -e MP_DATABASE_URL=jdbc:postgresql://pg:5432/bridgelinkdb \
  -e MP_DATABASE_USERNAME=bridgelinktest -e MP_DATABASE_PASSWORD=bridgelinktest
if wait_for_log bl-pg 'successfully started' 120; then
  docker logs bl-pg 2>&1 | grep -q ', postgres,' && ok "using postgres backend" || bad "not on postgres"
  [ "$(api_code "$(https_port bl-pg)")" = "200" ] && ok "API 200 (postgres)" || bad "API not 200 (postgres)"
else
  bad "server did not start (postgres)"; docker logs bl-pg 2>&1 | tail -20
fi

# ---- 7. Graceful shutdown (SIGTERM forwarding) ------------------------------------------------
info "7. Graceful shutdown"
docker stop bl-derby >/dev/null 2>&1
docker logs bl-derby 2>&1 | grep -qi 'shutting down mirth' && ok "graceful shutdown logged" || bad "no graceful shutdown"

# ---- 8. appdata persistence across restart ----------------------------------------------------
info "8. Persistence across restart"
docker volume create bl-dhi-appdata >/dev/null
run bl-persist -p 8443 -v bl-dhi-appdata:/opt/bridgelink/appdata \
  -e SERVER_ID=abcdef00-0000-0000-0000-000000000000
if wait_for_log bl-persist; then
  docker cp bl-persist:/opt/bridgelink/appdata/server.id "$WORK/sidA" >/dev/null 2>&1
  docker cp bl-persist:/opt/bridgelink/appdata/keystore.jks "$WORK/ksA" >/dev/null 2>&1
  docker restart bl-persist >/dev/null
  if wait_for_log bl-persist; then
    docker cp bl-persist:/opt/bridgelink/appdata/server.id "$WORK/sidB" >/dev/null 2>&1
    docker cp bl-persist:/opt/bridgelink/appdata/keystore.jks "$WORK/ksB" >/dev/null 2>&1
    cmp -s "$WORK/sidA" "$WORK/sidB" && ok "server.id persisted" || bad "server.id changed"
    cmp -s "$WORK/ksA" "$WORK/ksB" && ok "keystore persisted" || bad "keystore changed"
  else
    bad "did not restart"
  fi
else
  bad "server did not start (persist)"
fi
docker volume rm bl-dhi-appdata >/dev/null 2>&1 || true

# ---- summary ----------------------------------------------------------------------------------
echo
echo "==================== RESULT: $PASS passed, $FAIL failed ===================="
[ "$FAIL" -eq 0 ]
