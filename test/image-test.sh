#!/usr/bin/env bash
#
# Automated acceptance tests for the BridgeLink container images — IRT-1356 (DHI), IRT-1391 (Rocky).
# Asserts boot + config-injection parity across the hardened (DHI) and Rocky images from one suite.
#
# Parameterized by env var:
#   IMAGE           image to test (default innovarhealthcare/bridgelink:dhi-test)
#   DOCKERFILE      Dockerfile to build when SKIP_BUILD!=1 (default Dockerfile.dhi; Dockerfile for Rocky)
#   EXPECTED_UID    non-root UID the image must run as (default 65532; 1000 for Rocky)
#   CHECK_NO_SHELL  1 = assert the runtime has no shell (DHI); 0 = skip (Rocky has a shell)
#   SKIP_BUILD      1 = test an existing IMAGE instead of building
#
# Usage:
#   # DHI (defaults):
#   BINARY_URL="https://.../BridgeLink_unix_26_3_1.tar.gz" test/image-test.sh
#   IMAGE=innovarhealthcare/bridgelink:26.3.1-dhi SKIP_BUILD=1 test/image-test.sh
#   # Rocky:
#   BINARY_URL="https://.../..." IMAGE=innovarhealthcare/bridgelink:rocky-test \
#     DOCKERFILE=Dockerfile EXPECTED_UID=1000 CHECK_NO_SHELL=0 test/image-test.sh
#
# Requires: docker (with buildx), python3, curl. Building the DHI image needs `docker login dhi.io`.
set -u

IMAGE="${IMAGE:-innovarhealthcare/bridgelink:dhi-test}"
SKIP_BUILD="${SKIP_BUILD:-0}"
DOCKERFILE="${DOCKERFILE:-Dockerfile.dhi}"
EXPECTED_UID="${EXPECTED_UID:-65532}"
CHECK_NO_SHELL="${CHECK_NO_SHELL:-1}"
NET="bl-test-net-$$"
WORK="$(mktemp -d)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PASS=0 FAIL=0

# ---- helpers ----------------------------------------------------------------------------------
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
info() { echo "== $1"; }

cleanup() {
  # ${CIDS[@]+...}: empty-array expansion is an "unbound variable" error under set -u on bash 3.2
  # (macOS /bin/bash), which would abort cleanup entirely.
  docker rm -f ${CIDS[@]+"${CIDS[@]}"} >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker volume rm bl-dhi-appdata >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
CIDS=()
trap cleanup EXIT
run() { local name="$1"; shift; CIDS+=("$name"); docker run -d --name "$name" "$@" "$IMAGE" >/dev/null; }

# vmoptions assertions differ by launcher: the DHI bootstrap echoes the assembled JVM command line to
# stdout (so we grep the log — this also exercises the bootstrap's add-opens dedup logic); the Rocky
# ./blserver vendor launcher does not, so we inspect blserver.vmoptions on disk. Same net assertion.
vmopt_has() {   # <container> <fixed-string>  -> return 0 if present
  if [ "$CHECK_NO_SHELL" = "1" ]; then
    docker logs "$1" 2>&1 | grep -q -- "$2"
  else
    docker cp "$1:/opt/bridgelink/blserver.vmoptions" "$WORK/_vmo" >/dev/null 2>&1 && grep -q -- "$2" "$WORK/_vmo"
  fi
}
vmopt_count() {  # <container> <pattern>  -> echo occurrence count
  if [ "$CHECK_NO_SHELL" = "1" ]; then
    docker logs "$1" 2>&1 | grep -o "$2" | wc -l | tr -d ' '
  elif docker cp "$1:/opt/bridgelink/blserver.vmoptions" "$WORK/_vmo" >/dev/null 2>&1; then
    # grep -c prints "0" and exits 1 on no match; keep just the count, swallow the exit.
    grep -c "$2" "$WORK/_vmo" 2>/dev/null || true
  else
    echo 0
  fi
}

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
# Includes a raw Latin-1 byte (0xE9, é) — regression guard: a non-UTF-8 customer file must not
# crash the bootstrap (it reads/writes ISO-8859-1, the java.util.Properties charset).
printf 'secret.injected.prop = fromSecret\ndatabase.max-connections = 42\nsecret.latin1.prop = caf\xe9pass\n' > "$WORK/secrets/mirth_properties"
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
  info "Building $IMAGE from $DOCKERFILE"
  : "${BINARY_URL:?set BINARY_URL to build, or set SKIP_BUILD=1 to test an existing IMAGE}"
  docker build -f "$REPO_ROOT/$DOCKERFILE" --load \
    --build-arg BINARY_URL="$BINARY_URL" \
    ${AWS_CREDENTIALS_FILE:+--secret id=aws_credentials,src=$AWS_CREDENTIALS_FILE} \
    -t "$IMAGE" "$REPO_ROOT" || { echo "BUILD FAILED"; exit 1; }
fi

docker network create "$NET" >/dev/null

# ---- 1. Hardening: no shell / no bash in the runtime (DHI only) -------------------------------
if [ "$CHECK_NO_SHELL" = "1" ]; then
  info "1. Hardened runtime has no shell"
  if docker run --rm --entrypoint sh "$IMAGE" -c 'echo x' >/dev/null 2>&1; then bad "sh present"; else ok "no sh"; fi
  if docker run --rm --entrypoint /bin/bash "$IMAGE" -c 'echo x' >/dev/null 2>&1; then bad "bash present"; else ok "no bash"; fi
else
  info "1. No-shell check skipped (CHECK_NO_SHELL=0 — the Rocky image ships a shell by design)"
fi

# ---- 2. Runs non-root as the expected UID -----------------------------------------------------
info "2. Non-root UID $EXPECTED_UID"
U="$(docker image inspect "$IMAGE" --format '{{.Config.User}}')"
if printf '%s' "$U" | grep -qE '^[0-9]+$'; then
  RUID="$U"   # numeric USER directive (e.g. DHI 'USER 65532')
else
  # Rocky sets USER by name ('USER bridgelink'); resolve the effective uid via the shell it ships.
  RUID="$(docker run --rm --entrypoint id "$IMAGE" -u 2>/dev/null | tr -d '[:space:]')"
fi
[ "$RUID" = "$EXPECTED_UID" ] && ok "runs as non-root uid $EXPECTED_UID (User=$U)" || bad "uid=$RUID User=$U (expected $EXPECTED_UID)"

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
  vmopt_has bl-derby '-Xmx512m' && ok "MP_VMOPTIONS -Xmx applied" || bad "MP_VMOPTIONS not applied"
  # add-opens must appear exactly once (dedup)
  N="$(vmopt_count bl-derby 'add-opens=java.base/java.util=ALL-UNNAMED')"
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
  # Whitespace-tolerant around '=': entrypoint.sh (Rocky) writes "key  =  value", the bootstrap "key = value".
  grep -qE '^secret\.injected\.prop[[:space:]]*=[[:space:]]*fromSecret' "$WORK/mp2" && ok "properties secret merged" || bad "properties secret not merged"
  # -a: the 0xE9 byte makes grep treat the file as binary otherwise
  grep -aqE '^secret\.latin1\.prop[[:space:]]*=[[:space:]]*caf' "$WORK/mp2" && ok "Latin-1 secret survives (charset regression)" || bad "Latin-1 secret missing (charset regression)"
  vmopt_has bl-secrets '-Dsecret.vmopt=enabled' && ok "vmoptions secret appended" || bad "vmoptions secret missing"
  docker cp bl-secrets:/opt/bridgelink/extensions/myextension/plugin.txt "$WORK/pl" >/dev/null 2>&1 \
    && ok "custom-extension zip extracted" || bad "custom-extension not extracted"
else
  bad "server did not start (secrets)"
fi

# ---- 5. HTTP download knobs (all via the HttpClient curl-replacement) -------------------------
# Extra HTTP-served fixtures. custom.properties reuses the valid mirth.properties captured in test 3
# (download-and-overwrite needs a complete file), plus a marker to assert the overwrite happened.
cp "$WORK/mp" "$WORK/httproot/custom.properties"; echo "custom.download.marker = downloaded" >> "$WORK/httproot/custom.properties"
printf -- '-server\n-Xmx333m\n-Djava.awt.headless=true\n-Dcustom.vmopt.marker=downloaded\n' > "$WORK/httproot/custom.vmoptions"
head -c 2048 /dev/urandom > "$WORK/httproot/keystore.jks"   # dummy bytes: tests the download path, not JKS validity
python3 - "$WORK" <<'PY'
import os, sys, zipfile
w = sys.argv[1]; d = os.path.join(w, "cjar"); os.makedirs(d, exist_ok=True)
open(os.path.join(d, "lib.txt"), "w").write("custom jar payload\n")
with zipfile.ZipFile(os.path.join(w, "httproot", "custom-jars.zip"), "w") as z:
    z.write(os.path.join(d, "lib.txt"), "mycustomjar/lib.txt")
PY

docker run -d --name fileserver --network "$NET" \
  -v "$WORK/httproot:/usr/share/nginx/html:ro" nginx:alpine >/dev/null && CIDS+=(fileserver)
sleep 2

info "5a. EXTENSIONS_DOWNLOAD"
run bl-dl --network "$NET" -e EXTENSIONS_DOWNLOAD="http://fileserver/myextension.zip"
if wait_for_log bl-dl; then
  docker cp bl-dl:/opt/bridgelink/extensions/myextension/plugin.txt "$WORK/pl2" >/dev/null 2>&1 \
    && ok "downloaded + extracted via HttpClient" || bad "HTTP download/extract failed"
else
  bad "server did not start (download)"
fi

info "5b. CUSTOM_PROPERTIES / CUSTOM_VMOPTIONS / CUSTOM_JARS_DOWNLOAD"
run bl-knobs --network "$NET" \
  -e CUSTOM_PROPERTIES="http://fileserver/custom.properties" \
  -e CUSTOM_VMOPTIONS="http://fileserver/custom.vmoptions" \
  -e CUSTOM_JARS_DOWNLOAD="http://fileserver/custom-jars.zip"
if wait_for_log bl-knobs; then
  docker cp bl-knobs:/opt/bridgelink/conf/mirth.properties "$WORK/mp3" >/dev/null 2>&1
  grep -q '^custom.download.marker = downloaded' "$WORK/mp3" && ok "CUSTOM_PROPERTIES overwrote mirth.properties" || bad "CUSTOM_PROPERTIES not applied"
  vmopt_has bl-knobs '-Dcustom.vmopt.marker=downloaded' && ok "CUSTOM_VMOPTIONS applied" || bad "CUSTOM_VMOPTIONS not applied"
  docker cp bl-knobs:/opt/bridgelink/custom-jars/mycustomjar/lib.txt "$WORK/cj" >/dev/null 2>&1 && ok "CUSTOM_JARS_DOWNLOAD extracted" || bad "CUSTOM_JARS_DOWNLOAD not extracted"
else
  bad "server did not start (custom knobs)"
fi

info "5c. KEYSTORE_DOWNLOAD (verifies download writes appdata/keystore.jks)"
run bl-ks --network "$NET" -e KEYSTORE_DOWNLOAD="http://fileserver/keystore.jks"
# The download happens before launch; don't gate on the (deliberately bogus) keystore booting.
# Poll rather than fixed-sleep — a slow runner made a fixed sleep flaky.
KS_OK=1 i=0
while [ "$i" -lt 60 ]; do
  if docker cp bl-ks:/opt/bridgelink/appdata/keystore.jks "$WORK/ks-dl" >/dev/null 2>&1 \
     && cmp -s "$WORK/httproot/keystore.jks" "$WORK/ks-dl"; then KS_OK=0; break; fi
  sleep 1; i=$((i+1))
done
[ "$KS_OK" -eq 0 ] && ok "KEYSTORE_DOWNLOAD wrote appdata/keystore.jks" || bad "keystore download bytes differ/missing"

info "5d. ALLOW_INSECURE over self-signed https"
if command -v openssl >/dev/null; then
  mkdir -p "$WORK/tls"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=fileserver-https" \
    -keyout "$WORK/tls/key.pem" -out "$WORK/tls/cert.pem" >/dev/null 2>&1
  cat > "$WORK/tls/default.conf" <<'NG'
server {
  listen 443 ssl;
  ssl_certificate     /etc/nginx/certs/cert.pem;
  ssl_certificate_key /etc/nginx/certs/key.pem;
  location / { root /usr/share/nginx/html; }
}
NG
  docker run -d --name fileserver-https --network "$NET" \
    -v "$WORK/httproot:/usr/share/nginx/html:ro" \
    -v "$WORK/tls:/etc/nginx/certs:ro" \
    -v "$WORK/tls/default.conf:/etc/nginx/conf.d/default.conf:ro" \
    nginx:alpine >/dev/null && CIDS+=(fileserver-https)
  sleep 2
  # (a) ALLOW_INSECURE=true -> self-signed cert accepted, download succeeds
  run bl-insec --network "$NET" -e ALLOW_INSECURE=true \
    -e EXTENSIONS_DOWNLOAD="https://fileserver-https/myextension.zip"
  if wait_for_log bl-insec; then
    docker cp bl-insec:/opt/bridgelink/extensions/myextension/plugin.txt "$WORK/pi" >/dev/null 2>&1 \
      && ok "ALLOW_INSECURE=true downloads over self-signed https" || bad "insecure https download failed"
  else bad "server did not start (insecure)"; fi
  # (b) no ALLOW_INSECURE -> cert rejected, extension absent, server still boots (failure is non-fatal)
  run bl-sec --network "$NET" -e EXTENSIONS_DOWNLOAD="https://fileserver-https/myextension.zip"
  if wait_for_log bl-sec; then
    if docker cp bl-sec:/opt/bridgelink/extensions/myextension/plugin.txt "$WORK/psf" >/dev/null 2>&1; then
      bad "self-signed https downloaded WITHOUT ALLOW_INSECURE (cert not verified)"
    else ok "self-signed https rejected without ALLOW_INSECURE"; fi
  else bad "server did not start (secure)"; fi
else
  echo "  SKIP: openssl not available — ALLOW_INSECURE lane"
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

# ---- 6b. MySQL backend ------------------------------------------------------------------------
info "6b. MySQL backend"
docker run -d --name mysql --network "$NET" \
  -e MYSQL_ROOT_PASSWORD=rootpw -e MYSQL_DATABASE=bridgelinkdb \
  -e MYSQL_USER=bridgelinktest -e MYSQL_PASSWORD=bridgelinktest \
  mysql:8 >/dev/null && CIDS+=(mysql)
# allowPublicKeyRetrieval+useSSL=false: MySQL 8 defaults to caching_sha2_password, which needs one
# of these for first auth over a plaintext connection. MP_DATABASE_MAX_RETRY widens the retry
# window past MySQL 8's cold-init (~20-30s), which can exceed the default 2x10s on a cold runner.
run bl-mysql --network "$NET" -p 8443 \
  -e MP_DATABASE=mysql \
  -e MP_DATABASE_URL="jdbc:mysql://mysql:3306/bridgelinkdb?allowPublicKeyRetrieval=true&useSSL=false" \
  -e MP_DATABASE_USERNAME=bridgelinktest -e MP_DATABASE_PASSWORD=bridgelinktest \
  -e MP_DATABASE_MAX_RETRY=15
if wait_for_log bl-mysql 'successfully started' 180; then
  docker logs bl-mysql 2>&1 | grep -q ', mysql,' && ok "using mysql backend" || bad "not on mysql"
  [ "$(api_code "$(https_port bl-mysql)")" = "200" ] && ok "API 200 (mysql)" || bad "API not 200 (mysql)"
else
  bad "server did not start (mysql)"; docker logs bl-mysql 2>&1 | tail -20
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
