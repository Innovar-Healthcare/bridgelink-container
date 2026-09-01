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
#   EXPECT_NO_ADMIN_CLIENT  1 = assert the Swing Administrator (client-lib, public_html) is absent
#                           (WebAdmin-only image built with INCLUDE_ADMIN_CLIENT=false); 0 = skip
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

# Poll docker's own healthcheck verdict until it reaches $2 (default: healthy). Returns non-zero on
# timeout. Health goes through "starting" first, so a bare inspect right after `run` proves nothing.
wait_for_health() {
  local name="$1" want="${2:-healthy}" timeout="${3:-180}" i=0 got=
  while [ "$i" -lt "$timeout" ]; do
    got="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null)"
    [ "$got" = "$want" ] && return 0
    sleep 1; i=$((i+1))
  done
  echo "    (last health status: ${got:-unknown})"
  return 1
}

# Is 8443 still answering TLS+HTTP at all? Measured from the HOST, so it depends on nothing inside
# the image — the assertion is precisely that the port stays open while the engine is not OK.
# `%{http_code}` is 000 when the connection or handshake fails and an HTTP status otherwise, so any
# non-000 means the port answered. Deliberately NOT `-f`: the status code is irrelevant here, only
# whether something replied.
port_answers() {
  local code
  code="$(curl -k -s -o /dev/null -m 10 -w '%{http_code}' "https://localhost:$1/" 2>/dev/null)"
  [ -n "$code" ] && [ "$code" != "000" ]
}

# The reporter's exact healthcheck from issue #38, for the side-by-side in test 6c.
reporter_check() { curl -kf -s -o /dev/null -m 10 "https://localhost:$1"; }

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

# ---- 0. Unit: healthcheck response parsing (host-side, no container) --------------------------
# Guards the one piece of real logic in the probe. Skipped rather than failed where there is no JDK
# on the host: this suite's contract is to test an image, and a missing host javac is not an image
# defect. CI runners have one.
info "0. Healthcheck response parsing (unit)"
if command -v javac >/dev/null && command -v java >/dev/null; then
  if javac -d "$WORK/unit" "$REPO_ROOT/bootstrap/BridgeLinkHealthcheck.java" \
       "$SCRIPT_DIR/BridgeLinkHealthcheckParseTest.java" >"$WORK/javac.log" 2>&1; then
    if java -cp "$WORK/unit" BridgeLinkHealthcheckParseTest; then
      ok "parseStatus handles both response shapes and rejects digit-bearing error bodies"
    else
      bad "parseStatus unit cases failed (see above)"
    fi
  else
    bad "healthcheck probe did not compile"; cat "$WORK/javac.log"
  fi
else
  echo "  SKIP: no host JDK — parse unit cases not run"
fi

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

# ---- 2b. WebAdmin-only image: Swing Administrator stripped ------------------------------------
# Image-filesystem assertion (no running container needed). `docker export | tar -t` is
# shell-independent, so it works for the no-shell DHI runtime too. Boot + API parity for the
# stripped image is still covered by tests 3-8 below (they run against whatever IMAGE is given).
if [ "${EXPECT_NO_ADMIN_CLIENT:-0}" = "1" ]; then
  info "2b. Swing Administrator stripped (client-lib, public_html absent)"
  CTMP="$(docker create "$IMAGE")"; CIDS+=("$CTMP")
  if docker export "$CTMP" | tar -t 2>/dev/null | grep -qE 'opt/bridgelink/(client-lib|public_html)/'; then
    bad "client-lib/public_html still present (INCLUDE_ADMIN_CLIENT strip did not run)"
  else
    ok "client-lib and public_html absent"
  fi
fi

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
  # insecure-alias: a SECOND name for the same server, deliberately not the cert's CN, so lane (c)
  # below can fetch the same file through a name the certificate does not cover.
  docker run -d --name fileserver-https --network "$NET" --network-alias insecure-alias \
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

  # (c) HOSTNAME mismatch under ALLOW_INSECURE — regression guard for IRT-2015.
  #
  # Cases (a)/(b) above cannot catch the bug they look like they cover: the cert is issued for
  # CN=fileserver-https and fetched from exactly that name, so it matches (Java falls back to CN
  # when a cert carries no SAN). This lane fetches the SAME cert through a different hostname, so
  # the identity check has to fail unless it is genuinely disabled.
  #
  # What it caught: ALLOW_INSECURE=true made the DHI bootstrap trust any certificate but left
  # HttpClient's hostname verification on — that check is independent of the SSLContext and cannot
  # be switched off through it. Rocky's `curl -k` skips both, so this worked on one image and not
  # the other, contradicting the bootstrap's "both images behave identically" contract. Runs
  # against whichever IMAGE is under test, which is the point: it is a parity assertion.
  run bl-hostmm --network "$NET" -e ALLOW_INSECURE=true \
    -e EXTENSIONS_DOWNLOAD="https://insecure-alias/myextension.zip"
  if wait_for_log bl-hostmm; then
    docker cp bl-hostmm:/opt/bridgelink/extensions/myextension/plugin.txt "$WORK/phm" >/dev/null 2>&1 \
      && ok "ALLOW_INSECURE=true ignores a hostname mismatch (cert CN != URL host)" \
      || bad "hostname mismatch still rejected with ALLOW_INSECURE=true (IRT-2015 regression)"
  else bad "server did not start (hostname mismatch)"; fi
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

# ---- 6c. HEALTHCHECK: declared, reaches healthy, and reflects ENGINE state not port state -----
# IRT-2015 / issue #38. Consumes the bl-pg + pg pair from test 6 (which is finished with them) —
# tests 7 and 8 below use bl-derby and bl-persist, so nothing later depends on them.
#
# The third assertion is the one that matters. `curl -kf https://localhost:8443` (what the reporter
# had, and all a port check can do) passes as soon as Jetty is listening, which happens BEFORE the
# engine starts and before the initial channel deploy. So the probe has to be shown reporting
# unhealthy while the port is still perfectly answerable. That is why the DB is stopped UNDER a
# running server rather than never provided: with no DB at boot the server exhausts its connection
# retries and exits before it ever opens 8443, so the container would just die and a port check
# would "fail" too — proving nothing about the probe.
info "6c. HEALTHCHECK"

HC="$(docker image inspect "$IMAGE" --format '{{if .Config.Healthcheck}}{{json .Config.Healthcheck.Test}}{{else}}none{{end}}')"
case "$HC" in
  none) bad "image declares no HEALTHCHECK" ;;
  *CMD-SHELL*) bad "HEALTHCHECK uses CMD-SHELL — needs /bin/sh, which the hardened runtime lacks ($HC)" ;;
  *BridgeLinkHealthcheck*) ok "image declares an exec-form HEALTHCHECK ($HC)" ;;
  *) bad "unexpected HEALTHCHECK: $HC" ;;
esac

if docker inspect bl-pg --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
  PGPORT="$(https_port bl-pg)"
  if wait_for_health bl-pg healthy 180; then
    ok "container reports healthy while the engine is up"

    # Stop the database out from under a healthy server. Jetty keeps listening; getStatus() flips to
    # UNAVAILABLE because isDatabaseRunning() goes false.
    #
    # Timing note, because 300s of --start-period looks like it should make this test take 5 minutes
    # and does not: docker treats the container as started the moment a check first SUCCEEDS during
    # the start period, after which failures count toward --retries immediately. The container went
    # healthy above, so the flip takes retries x interval (~45s), not the full start period.
    docker stop pg >/dev/null 2>&1
    if wait_for_health bl-pg unhealthy 120; then
      if port_answers "$PGPORT"; then
        ok "health flips to unhealthy on DB loss WHILE 8443 still answers (the port check could not see this)"
        # The whole point of issue #38, made explicit: the old check is green here and is wrong.
        if reporter_check "$PGPORT"; then
          ok "side-by-side: \`curl -kf https://localhost:8443\` still PASSES here — why it was the wrong check"
        else
          echo "  NOTE: the reporter's bare curl -kf also failed at this moment; the port-vs-engine"
          echo "        distinction is still proven by the assertion above, which ignores status codes."
        fi
      else
        # Not a pass: if the port died too, this run did not discriminate between the two at all.
        bad "health went unhealthy but 8443 stopped answering — assertion did not isolate engine state from port state"
      fi
      # Healthcheck output lands in .State.Health.Log[].Output, never in container stdout. Two
      # reasons are both correct here, and which one you get depends on the failure: "status 1"
      # when getStatus() returns UNAVAILABLE, or a read timeout when it BLOCKS instead — for total
      # database loss the timeout is what actually happens, because isDatabaseRunning() ->
      # testDatabase() waits on the connection pool rather than failing fast. Asserting only
      # "status 1" pinned the wrong one of the two and failed a run where the probe behaved
      # correctly. What must hold is that the probe, not docker's timeout killer, produced a
      # readable reason — an empty Output would mean the probe was killed with nothing to show.
      HLOG="$(docker inspect bl-pg --format '{{range .State.Health.Log}}{{.Output}}{{end}}' 2>/dev/null)"
      if printf '%s' "$HLOG" | grep -qE 'unhealthy:.*(status 1|Timeout|timed out)'; then
        ok "probe recorded a diagnosable reason ($(printf '%s' "$HLOG" | grep -o 'unhealthy:.*' | tail -1 | cut -c1-90))"
      else
        bad "probe verdict recorded without a usable reason in .State.Health.Log"
        printf '    health log: %s\n' "$(printf '%s' "$HLOG" | tail -c 300)"
      fi

      # Liveness rationale, pinned empirically rather than asserted in a comment: /version keeps
      # answering while /status is unusable. This is why the chart's livenessProbe targets /version
      # — pointed at /status it would time out and restart the pod on any database outage.
      VCODE="$(curl -k -s -o /dev/null -m 10 -w '%{http_code}' -H 'X-Requested-With: XMLHttpRequest' \
                 "https://localhost:$PGPORT/api/server/version" 2>/dev/null)"
      SCODE="$(curl -k -s -o /dev/null -m 10 -w '%{http_code}' -H 'X-Requested-With: XMLHttpRequest' \
                 "https://localhost:$PGPORT/api/server/status" 2>/dev/null)"
      if [ "$VCODE" = "200" ] && [ "$SCODE" != "200" ]; then
        ok "/api/server/version still 200 while /api/server/status is unusable ($SCODE) — why liveness uses version"
      else
        # Not fatal to the change, but the chart's liveness target is chosen on this behaviour, so
        # say so loudly if it ever stops holding.
        echo "  NOTE: version=$VCODE status=$SCODE — expected version 200 and status not-200 with the DB down."
        echo "        If /status now fails fast instead of blocking, revisit the chart's livenessProbe target."
      fi
    else
      bad "health did not become unhealthy after the database was stopped"
      docker inspect bl-pg --format '{{json .State.Health}}' 2>/dev/null | head -c 600; echo
    fi
  else
    bad "container never reported healthy"
    docker inspect bl-pg --format '{{json .State.Health}}' 2>/dev/null | head -c 600; echo
  fi
else
  bad "bl-pg is not running — cannot exercise the healthcheck (see test 6)"
fi

# ---- 7. Graceful shutdown (SIGTERM forwarding) ------------------------------------------------
# What this image owes: PID 1 forwards docker's SIGTERM to the server, which then closes down of its
# own accord instead of being SIGKILLed when the grace period expires.
#
# Asserted on two race-free signals:
#   exit 143 (128+SIGTERM) -- the signal reached the server and it exited on it. A force-kill at the
#                             end of the grace period would be 137, and a crash some other code.
#   "Database shut down normally." -- written straight to stdout by the database layer rather than
#                             through the application logger, so it is proof the shutdown actually
#                             ran to completion and not merely that the process died.
#
# The server's own "shutting down" log line is deliberately NOT the assertion. It is emitted from a
# JVM shutdown hook, and hooks run concurrently in unspecified order, so the logger's teardown hook
# can drop the message even on a perfectly clean shutdown -- measured at 2 losses in 40 local runs,
# and it failed CI runs 30803286012 and 31367340279 while the shutdown itself was fine. Kept below as
# an informational note so a change in logging behaviour is still visible without gating the build.
#
# -t 30 leaves a loaded CI runner room to finish before docker escalates to SIGKILL, without hiding a
# genuine hang: a hang still lands on 137 and fails.
info "7. Graceful shutdown"
docker stop -t 30 bl-derby >/dev/null 2>&1
SHUT_EC="$(docker inspect bl-derby --format '{{.State.ExitCode}}' 2>/dev/null || echo '?')"
DB_CLOSED=0
docker logs bl-derby 2>&1 | grep -q 'Database shut down normally' && DB_CLOSED=1
if [ "$SHUT_EC" = "143" ] && [ "$DB_CLOSED" = "1" ]; then
  ok "graceful shutdown (exit 143 on SIGTERM, database closed normally)"
else
  bad "no graceful shutdown (exit=$SHUT_EC, database-closed=$DB_CLOSED)"
  docker logs bl-derby 2>&1 | tail -20
fi
docker logs bl-derby 2>&1 | grep -qi 'shutting down' \
  || echo "  NOTE: server shutdown log line absent (known logger-teardown race; graceful shutdown is" \
          "asserted above on exit code + database close, not on this line)"

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
